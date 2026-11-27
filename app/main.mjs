import { readFileSync } from 'node:fs';
import process from 'node:process';
import { createApplication } from './http.mjs';
import { createServers } from './server.mjs';
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
const { web, scraper } = createServers(app);
const servers = [web, scraper];
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
