import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import test from 'node:test';
import { passwordHash } from '../app/auth.mjs';
import { createApplication } from '../app/http.mjs';
import { backupDatabase, inspectBackup, openStore } from '../app/store.mjs';

const origin = 'https://desk.lab.invalid';
const password = 'synthetic acceptance passphrase';
const profile = await passwordHash(password);
const createFields = { title: 'Review rotated fixture certificates', severity: 'high' };

function arrange(t) {
  const folder = mkdtempSync(join(tmpdir(), 'security-desk-test-'));
  const path = join(folder, 'desk.sqlite');
  let store = openStore(path);
  let timestamp = Date.parse('2026-01-01T00:00:00Z');
  const key = randomBytes(32);
  const logLines = [];
  store.insertUser('operator', 'admin', profile);
  store.insertUser('reviewer', 'viewer', profile);
  const build = () => createApplication({
    store, key, origin, clock: () => timestamp, log: (line) => logLines.push(line),
  });
  let app = build();
  t.after(() => {
    store.close();
    rmSync(folder, { recursive: true });
  });
  return {
    folder, path, logLines,
    advance: (ms) => { timestamp += ms; },
    reopen() {
      store.close();
      store = openStore(path);
      app = build();
    },
    metrics: () => app.metrics(),
    async call(method, url, { body, raw, headers = {}, session } = {}) {
      const input = raw ?? (body === undefined ? '' : JSON.stringify(body));
      const req = Readable.from(input.length ? [Buffer.from(input)] : []);
      req.method = method;
      req.url = url;
      req.headers = { origin, ...headers };
      if (body) req.headers['content-type'] ??= 'application/json';
      if (session) {
        req.headers.cookie = session.cookie;
        req.headers['x-csrf-token'] ??= session.csrf;
      }
      const result = { headers: {}, statusCode: 0, data: '' };
      result.setHeader = (name, value) => { result.headers[name] = value; };
      result.writeHead = (status, values) => {
        result.statusCode = status;
        Object.assign(result.headers, values);
      };
      result.end = (data) => { result.data = data?.toString() ?? ''; };
      await app.handle(req, result);
      if (result.data && result.headers['content-type'].startsWith('application/json')) {
        result.json = JSON.parse(result.data);
      }
      return result;
    },
  };
}

async function signIn(ctx, username, cookie) {
  const result = await ctx.call('POST', '/api/session', {
    body: { username, password }, headers: cookie ? { cookie } : {},
  });
  assert.equal(result.statusCode, 200);
  return {
    cookie: result.headers['set-cookie'].split(';')[0], csrf: result.json.csrf,
    fullCookie: result.headers['set-cookie'],
  };
}

test('frontend has security headers and health probes use the real database', async (t) => {
  const ctx = arrange(t);
  const index = await ctx.call('GET', '/');
  assert.equal(index.statusCode, 200);
  assert.match(index.data, /<h1 id="sign-in-title">Sign in<\/h1>/);
  assert.match(index.headers['content-security-policy'], /frame-ancestors 'none'/);
  assert.equal(index.headers['cache-control'], 'no-store');
  assert.equal((await ctx.call('GET', '/healthz')).statusCode, 200);
  assert.equal((await ctx.call('GET', '/readyz')).statusCode, 200);
  assert.equal((await ctx.call('GET', '/metrics')).statusCode, 404);
  assert.equal((await ctx.call('GET', '/api/findings')).statusCode, 401);
});

test('sign-in rotates sessions, configures secure cookies, logs out and expires', async (t) => {
  const ctx = arrange(t);
  const first = await signIn(ctx, 'operator');
  assert.match(first.fullCookie, /^__Host-lab_session=[A-Za-z0-9_-]{43}; Path=\/; Max-Age=28800; Secure; HttpOnly; SameSite=Strict$/);
  const second = await signIn(ctx, 'operator', first.cookie);
  assert.notEqual(second.cookie, first.cookie);
  assert.equal((await ctx.call('GET', '/api/session', { session: first })).statusCode, 401);
  assert.equal((await ctx.call('GET', '/api/session', { session: second })).statusCode, 200);
  const logout = await ctx.call('DELETE', '/api/session', { session: second });
  assert.equal(logout.statusCode, 204);
  assert.match(logout.headers['set-cookie'], /Max-Age=0/);
  assert.equal((await ctx.call('GET', '/api/session', { session: second })).statusCode, 401);
  const third = await signIn(ctx, 'operator');
  ctx.advance(8 * 60 * 60 * 1000);
  assert.equal((await ctx.call('GET', '/api/session', { session: third })).statusCode, 401);
  assert.ok(ctx.logLines.every((line) => !line.includes(password) && !line.includes(second.csrf)));
});

test('admin can manage findings, viewer can read, and request guards deny boundary failures', async (t) => {
  const ctx = arrange(t);
  const admin = await signIn(ctx, 'operator');
  const viewer = await signIn(ctx, 'reviewer');
  const create = (session, headers, body = createFields) => ctx.call(
    'POST', '/api/findings', { session, headers, body },
  );

  assert.equal((await create(viewer)).json.error, 'role_denied');
  assert.equal((await create(admin, { origin: 'https://unrelated.invalid' })).json.error, 'origin_denied');
  assert.equal((await create(admin, { 'x-csrf-token': 'invalid' })).json.error, 'csrf_denied');
  assert.equal((await create(admin, {}, { ...createFields, severity: 'unknown' })).statusCode, 400);
  assert.equal((await create(admin, {}, { ...createFields, title: 'x'.repeat(5000) })).statusCode, 413);
  const saved = await create(admin);
  assert.equal(saved.statusCode, 201);
  const edited = await ctx.call('PATCH', `/api/findings/${saved.json.id}`, {
    session: admin, body: { status: 'resolved' },
  });
  assert.equal(edited.json.status, 'resolved');
  const listed = await ctx.call('GET', '/api/findings', { session: viewer });
  assert.deepEqual(listed.json.findings, [edited.json]);
  assert.match(ctx.metrics(), /desk_findings\{severity="high",status="resolved"\} 1/);
  const change = ctx.logLines.map(JSON.parse).find((event) => event.event === 'finding_updated');
  assert.equal(change.finding_id, saved.json.id);
  assert.equal(change.status, 'resolved');
});

test('a bounded sign-in fixture reaches the per-account rate limit and recovers', async (t) => {
  const ctx = arrange(t);
  const body = { username: 'fixture-reader', password };
  for (let attempt = 0; attempt < 8; attempt += 1) {
    assert.equal((await ctx.call('POST', '/api/session', { body })).statusCode, 401);
  }
  assert.equal((await ctx.call('POST', '/api/session', { body })).statusCode, 429);
  ctx.advance(5 * 60 * 1000);
  assert.equal((await ctx.call('POST', '/api/session', { body })).statusCode, 401);
});

test('an online SQLite backup restores records and a reopened app preserves state', async (t) => {
  const ctx = arrange(t);
  const admin = await signIn(ctx, 'operator');
  const stored = await ctx.call('POST', '/api/findings', { session: admin, body: createFields });
  assert.equal(stored.statusCode, 201);
  const restoredFile = join(ctx.folder, 'restored.sqlite');
  backupDatabase(ctx.path, restoredFile);
  assert.deepEqual(inspectBackup(restoredFile), { findings: 1 });
  const restored = openStore(restoredFile);
  try {
    assert.deepEqual(restored.listFindings(0).map((record) => ({ ...record })), [stored.json]);
  } finally {
    restored.close();
  }
  ctx.reopen();
  const original = await ctx.call('GET', '/api/findings', { session: admin });
  assert.deepEqual(original.json.findings, [stored.json]);
});
