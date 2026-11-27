import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import process from 'node:process';
import { createApplication } from './http.mjs';
import { openStore } from './store.mjs';

process.umask(0o077);
const { DB_PATH, SESSION_KEY_FILE, PUBLIC_ORIGIN } = process.env;
const key = readFileSync(SESSION_KEY_FILE);
if (key.length !== 32) throw new Error('SESSION_KEY_FILE must contain 32 random bytes');
const origin = new URL(PUBLIC_ORIGIN);
if (origin.protocol !== 'https:' || origin.origin !== PUBLIC_ORIGIN) {
  throw new Error('PUBLIC_ORIGIN must be a canonical HTTPS origin');
}
const store = openStore(DB_PATH);
const app = createApplication({ store, key, origin: origin.origin });
const options = { headersTimeout: 5000, requestTimeout: 10000, keepAliveTimeout: 3000, maxHeaderSize: 8192 };
const web = createServer(options, app.handle);
const scraper = createServer(options, (req, res) => {
  if (req.method !== 'GET' || req.url !== '/metrics') {
    res.writeHead(404);
    return res.end();
  }
  try {
    res.writeHead(200, { 'content-type': 'text/plain; version=0.0.4; charset=utf-8' });
    return res.end(app.metrics());
  } catch {
    res.destroy();
  }
});

const servers = [web, scraper];
for (const server of servers) {
  server.maxRequestsPerSocket = 100;
  server.maxConnections = 128;
  server.setTimeout(12000, (socket) => socket.destroy());
}
web.listen(8080, '0.0.0.0');
scraper.listen(9091, '0.0.0.0');

function shutdown() {
  const forced = setTimeout(() => process.exit(1), 12000);
  forced.unref();
  Promise.all(servers.map((server) => new Promise((resolve) => server.close(resolve)))).then(() => {
    store.close();
  });
}

process.once('SIGTERM', shutdown);
process.once('SIGINT', shutdown);
