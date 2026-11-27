import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

export function openChromium(executable, profile, flags = []) {
  const process = spawn(executable, [
    '--headless', '--disable-background-networking', '--disable-extensions', '--disable-sync',
    '--no-first-run', '--no-default-browser-check', '--no-proxy-server',
    `--user-data-dir=${profile}`, '--password-store=basic',
    ...flags, '--remote-debugging-pipe', 'about:blank',
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

export async function browserPage(browser, attempts = 50) {
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
    for (let attempt = 0; attempt < attempts; attempt += 1) {
      if (await evaluate(expression)) return;
      await delay(100);
    }
    throw new Error(message);
  }

  return { version, send, evaluate, expect };
}
