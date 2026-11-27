#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { createHash, X509Certificate } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { get } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parseArgs } from 'node:util';
import { browserPage, openChromium } from './lib/chromium.mjs';

const host = 'desk.lab.invalid';
const port = 8443;
const origin = `https://${host}:${port}`;
const findingTitle = 'Review synthetic image findings';

function certificatePin(ca) {
  return new Promise((resolve, reject) => {
    const request = get({
      hostname: '127.0.0.1', port, path: '/readyz', ca, servername: host,
      headers: { host: `${host}:${port}` }, agent: false, timeout: 5000,
    }, (response) => {
      response.resume();
      if (response.statusCode !== 200) {
        reject(new Error('The verified lab listener is unavailable'));
        return;
      }
      try {
        const certificate = new X509Certificate(response.socket.getPeerCertificate().raw);
        const spki = certificate.publicKey.export({ type: 'spki', format: 'der' });
        resolve(createHash('sha256').update(spki).digest('base64'));
      } catch (error) {
        reject(error);
      }
    });
    request.on('timeout', () => request.destroy(new Error('Timed out contacting the lab listener')));
    request.on('error', reject);
  });
}

async function verifyBrowser(browser, accounts) {
  const { version, send, evaluate, expect } = await browserPage(browser);

  async function signIn(username, password) {
    await evaluate(`(() => {
      document.querySelector('#username').value = ${JSON.stringify(username)};
      document.querySelector('#password').value = ${JSON.stringify(password)};
      document.querySelector('#sign-in').click();
    })()`);
    await expect(`document.querySelector('#account')?.textContent === ${JSON.stringify(username)}`,
      'The fixture user did not sign in');
  }

  const signInReady = 'document.querySelector("#sign-in")?.disabled === false';
  const recordVisible = `document.querySelectorAll('#findings tr').length === 1 &&
    document.querySelector('#findings td')?.textContent === ${JSON.stringify(findingTitle)}`;
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1200, height: 800, deviceScaleFactor: 1, mobile: false,
  });
  const navigation = await send('Page.navigate', { url: origin });
  if (navigation.errorText) throw new Error('Chromium could not open the verified lab origin');
  await expect(`location.origin === ${JSON.stringify(origin)} && (${signInReady})`,
    'The Chromium sign-in screen did not initialize');
  await signIn('fixture-operator', accounts.operator);
  await expect(`${recordVisible} && !document.querySelector('#add-form')?.hidden &&
    document.querySelector('#findings select')?.value === 'resolved'`,
  'The operator did not see the resolved synthetic record and edit controls');
  const operator = await send('Page.captureScreenshot', { format: 'png' });

  await evaluate("document.querySelector('#sign-out').click()");
  await expect("!document.querySelector('#login')?.hidden && !document.querySelector('#account')?.textContent",
    'Chromium did not return to sign-in');
  await signIn('fixture-viewer', accounts.viewer);
  await expect(`${recordVisible} && document.querySelector('#add-form')?.hidden &&
    document.querySelector('#findings tr td:last-child')?.textContent === 'Resolved' &&
    !document.querySelector('#findings select')`,
  'The reviewer did not see the resolved synthetic record in read-only mode');
  const viewer = await send('Page.captureScreenshot', { format: 'png' });

  await evaluate("document.querySelector('#sign-out').click()");
  await expect("!document.querySelector('#login')?.hidden && !document.querySelector('#account')?.textContent",
    'The fixture reviewer was unable to sign out');
  return { version: version.product, operator: operator.data, viewer: viewer.data };
}

try {
  const { values } = parseArgs({ options: {
    ca: { type: 'string' },
    'fixture-credentials': { type: 'string' },
    'report-dir': { type: 'string' },
    chromium: { type: 'string' },
  } });
  if (!values.ca || !values['fixture-credentials'] || !values['report-dir']) {
    throw new Error('Supply --ca, --fixture-credentials and --report-dir');
  }
  const binary = values.chromium ?? ['google-chrome', 'chromium', 'chromium-browser'].find((candidate) =>
    spawnSync(candidate, ['--version'], { stdio: 'ignore', timeout: 3000 }).status === 0);
  if (!binary) throw new Error('Chromium or Google Chrome is required');
  const accounts = JSON.parse(await readFile(values['fixture-credentials'], 'utf8'));
  if (![accounts.operator, accounts.viewer].every((credential) =>
    typeof credential === 'string' && credential.length >= 16 && Buffer.byteLength(credential) <= 128)) {
    throw new Error('Expected the disposable CI fixture account passwords');
  }
  const pin = await certificatePin(await readFile(values.ca));
  const profile = await mkdtemp(join(tmpdir(), 'dslab-browser-'));
  const browser = openChromium(binary, profile, [
    `--host-resolver-rules=MAP ${host} 127.0.0.1, MAP * ~NOTFOUND`,
    `--ignore-certificate-errors-spki-list=${pin}`,
  ]);
  try {
    const { version, operator, viewer } = await verifyBrowser(browser, accounts);
    const report = values['report-dir'];
    await mkdir(report, { recursive: true, mode: 0o700 });
    await writeFile(join(report, 'operator.png'), Buffer.from(operator, 'base64'));
    await writeFile(join(report, 'viewer.png'), Buffer.from(viewer, 'base64'));
    await writeFile(join(report, 'report.json'), JSON.stringify({
      browser: version, fixture: 'one synthetic resolved finding', operator: 'passed', reviewer: 'passed',
    }, null, 2) + '\n');
  } finally {
    await browser.stop();
    await rm(profile, { recursive: true, force: true });
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
