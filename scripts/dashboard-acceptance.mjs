#!/usr/bin/env node
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { browserPage, openChromium } from './lib/chromium.mjs';

const [chromium, passwordFile, report, mode, scanFile = 'evidence/live/docker-image-gate.json'] = process.argv.slice(2);
const origin = 'http://127.0.0.1:13000';
const panels = {
  'Ready desk replicas': 'Ready1',
  'Remediation progress': 'resolved / high1',
  'Falco alerts': 'Warning',
};

async function verify(page, password) {
  const { send, evaluate, expect } = page;
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1500, height: 1100, deviceScaleFactor: 1, mobile: false,
  });
  const login = await send('Page.navigate', { url: origin + '/login' });
  if (login.errorText) throw new Error('The dedicated Grafana login route was unavailable');
  await expect("Boolean(document.querySelector('input[name=user]'))", 'Grafana login did not render');
  await evaluate("document.querySelector('input[name=user]').focus()");
  await send('Input.insertText', { text: 'admin' });
  await evaluate("document.querySelector('input[name=password]').focus()");
  await send('Input.insertText', { text: password });
  await evaluate("document.querySelector('button[type=submit]').click()");
  await expect(`location.origin === ${JSON.stringify(origin)} && location.pathname !== '/login'`,
    'Grafana did not establish the local acceptance session');

  const dashboard = await send('Page.navigate', { url: origin + '/d/devsecops-lab?orgId=1&kiosk' });
  if (dashboard.errorText) throw new Error('The provisioned Grafana dashboard was unavailable');
  await expect(`location.pathname.startsWith('/d/devsecops-lab') && Object.entries(${JSON.stringify(panels)})
    .every(([label, value]) => {
      const panel = document.querySelector('[data-testid="data-testid Panel header ' + label + '"]');
      return panel?.textContent.replace(/\\s+/g, ' ').includes(value);
    })`, 'The expected live values did not render in the provisioned Grafana panels');
  return await send('Page.captureScreenshot', { format: 'png' });
}

try {
  if (!chromium || !passwordFile || !report) throw new Error('Supply Chromium, a password file and a report directory');
  if (mode && mode !== '--local-acceptance') throw new Error('Unrecognized dashboard acceptance mode');
  if (mode === '--local-acceptance') {
    const { findings_by_severity: findings } = JSON.parse(await readFile(scanFile, 'utf8'));
    if (!Number.isInteger(findings?.high) || findings.high < 0) throw new Error('Expected local Trivy severity totals');
    panels['Latest imported pipeline'] = 'Local acceptancePassed';
    panels['Image security'] = 'Local scanPassed';
    panels['Security findings by severity'] = `Local / high${findings.high}`;
  }
  const password = (await readFile(passwordFile, 'utf8')).trim();
  if (password.length < 32) throw new Error('Expected the generated Grafana lab password');
  const profile = await mkdtemp(join(tmpdir(), 'dslab-dashboard-'));
  const browser = openChromium(chromium, profile, [
    '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE 127.0.0.1',
  ]);
  try {
    const page = await browserPage(browser, 240);
    const screenshot = await verify(page, password);
    await mkdir(report, { recursive: true, mode: 0o700 });
    await writeFile(join(report, 'dashboard.png'), Buffer.from(screenshot.data, 'base64'));
    await writeFile(join(report, 'dashboard.json'), JSON.stringify({
      browser: page.version.product, dashboard: 'DevSecOps Lab', panels,
    }, null, 2) + '\n');
  } finally {
    await browser.stop();
    await rm(profile, { recursive: true, force: true });
  }
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
