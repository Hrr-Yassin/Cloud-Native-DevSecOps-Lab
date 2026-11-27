#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import { createHash, X509Certificate } from 'node:crypto';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { get } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { parseArgs } from 'node:util';

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

function openChromium(executable, profile, pin) {
  const process = spawn(executable, [
    '--headless', '--disable-background-networking', '--disable-extensions', '--disable-sync',
    '--no-first-run', '--no-default-browser-check', '--no-proxy-server',
    `--user-data-dir=${profile}`, '--password-store=basic',
    `--host-resolver-rules=MAP ${host} 127.0.0.1, MAP * ~NOTFOUND`,
    `--ignore-certificate-errors-spki-list=${pin}`, '--remote-debugging-pipe', 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
  const commands = new Map();
  let failure;
  let id = 0;
  let buffer = '';
  const closed = new Promise((resolve) => process.once('close', resolve));

  function fail(error) {
    failure = error;
    for (const command of commands.values()) {
      clearTimeout(command.timeout);
      command.reject(error);
    }
    commands.clear();
  }

  process.on('error', () => fail(new Error('Could not start Chromium')));
  process.on('exit', () => fail(new Error('Chromium exited before completing acceptance')));
  process.stdio[3].on('error', () => fail(new Error('Chromium command pipe closed')));
  process.stdio[4].setEncoding('utf8').on('data', (chunk) => {
    buffer += chunk;
    if (buffer.length > 16 * 1024 * 1024) {
      fail(new Error('Chromium response exceeded the fixture limit'));
      return;
    }
    let end = buffer.indexOf('\0');
    while (end !== -1) {
      const frame = buffer.slice(0, end);
      buffer = buffer.slice(end + 1);
      let response;
      try {
        response = JSON.parse(frame);
      } catch {
        fail(new Error('Chromium returned an invalid protocol frame'));
        return;
      }
      const command = commands.get(response.id);
      if (command) {
        commands.delete(response.id);
        clearTimeout(command.timeout);
        if (response.error) command.reject(new Error(`Chromium rejected ${command.method}`));
        else command.resolve(response.result);
      }
      end = buffer.indexOf('\0');
    }
  });

  return {
    send(method, params = {}, sessionId) {
      if (failure) return Promise.reject(failure);
      const number = ++id;
      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          commands.delete(number);
          reject(new Error(`Chromium timed out during ${method}`));
        }, 12000);
        commands.set(number, { resolve, reject, timeout, method });
        process.stdio[3].write(`${JSON.stringify({ id: number, method, params, sessionId })}\0`);
      });
    },
    async stop() {
      process.kill();
      const watchdog = setTimeout(() => process.kill('SIGKILL'), 2000);
      try {
        await closed;
      } finally {
        clearTimeout(watchdog);
      }
    },
  };
}

async function verifyBrowser(browser, accounts) {
  const version = await browser.send('Browser.getVersion');
  const { targetId } = await browser.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await browser.send('Target.attachToTarget', { targetId, flatten: true });
  const send = (method, params) => browser.send(method, params, sessionId);

  async function evaluate(expression) {
    const response = await send('Runtime.evaluate', { expression, returnByValue: true });
    if (response.exceptionDetails) throw new Error('The browser could not evaluate the fixture UI');
    return response.result.value;
  }

  async function expect(expression, message) {
    for (let attempt = 0; attempt < 50; attempt += 1) {
      if (await evaluate(expression)) return;
      await delay(100);
    }
    throw new Error(message);
  }

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
  const browser = openChromium(binary, profile, pin);
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
