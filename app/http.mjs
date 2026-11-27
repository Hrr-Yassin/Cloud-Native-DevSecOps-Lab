import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { digest, newToken, safeEqual, sessionCookie, sessionToken, validPassword,
  validUsername, verifyPassword } from './auth.mjs';
import { severities, statuses } from './store.mjs';

const assets = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/style.css', ['style.css', 'text/css; charset=utf-8']],
  ['/desk.mjs', ['desk.mjs', 'text/javascript; charset=utf-8']],
].map(([path, [file, type]]) => [
  path, { data: readFileSync(new URL(`./public/${file}`, import.meta.url)), type },
]));
const maximumBodyBytes = 4096;
const securityHeaders = {
  'cache-control': 'no-store',
  'content-security-policy': "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'",
  'permissions-policy': 'camera=(), microphone=(), geolocation=()',
  'referrer-policy': 'no-referrer',
  'strict-transport-security': 'max-age=15552000',
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
};

class HttpError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
  }
}

function send(res, status, model, headers = {}) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', ...headers });
  res.end(model === undefined ? undefined : JSON.stringify(model));
}

async function jsonBody(req, keys) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(req.headers['content-type'] ?? '')) {
    throw new HttpError(415, 'json_required');
  }
  if (Number(req.headers['content-length']) > maximumBodyBytes) {
    throw new HttpError(413, 'body_too_large');
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of req.iterator({ destroyOnReturn: false })) {
    size += chunk.length;
    if (size > maximumBodyBytes) throw new HttpError(413, 'body_too_large');
    chunks.push(chunk);
  }
  let body;
  try {
    body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
  } catch {
    throw new HttpError(400, 'invalid_json');
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).length !== keys.length || keys.some((key) => !Object.hasOwn(body, key))) {
    throw new HttpError(400, 'invalid_fields');
  }
  return body;
}

export function createApplication({ store, key, origin, clock = Date.now, log = console.log }) {
  const counts = { requests: 0, errors: 0, invalidLogins: 0, changes: 0 };
  let intervalStart = clock();
  const attempts = new Map();
  let loginCount = 0;
  let authenticating = 0;

  function event(name, requestId, fields = {}) {
    log(JSON.stringify({
      time: new Date(clock()).toISOString(), component: 'security-desk', event: name,
      request_id: requestId, ...fields,
    }));
  }

  function requireOrigin(req) {
    if (req.headers.origin !== origin) throw new HttpError(403, 'origin_denied');
  }

  function authenticate(req) {
    const token = sessionToken(req.headers.cookie);
    if (!token) throw new HttpError(401, 'authentication_required');
    const sessionDigest = digest(key, 'session', token);
    const user = store.findSession(sessionDigest, Math.floor(clock() / 1000));
    if (!user) throw new HttpError(401, 'authentication_required');
    return { user, sessionDigest, csrf: digest(key, 'csrf', token) };
  }

  function authorize(req, role) {
    requireOrigin(req);
    const session = authenticate(req);
    if (!safeEqual(req.headers['x-csrf-token'], session.csrf)) throw new HttpError(403, 'csrf_denied');
    if (role && session.user.role !== role) throw new HttpError(403, 'role_denied');
    return session;
  }

  async function login(req, res, requestId) {
    requireOrigin(req);
    const { username, password } = await jsonBody(req, ['username', 'password']);
    if (!validUsername(username) || !validPassword(password)) throw new HttpError(400, 'invalid_credentials_format');
    const now = clock();
    if (now - intervalStart >= 5 * 60 * 1000) {
      attempts.clear();
      loginCount = 0;
      intervalStart = now;
    }
    const previousAttempts = attempts.get(username) ?? 0;
    if (previousAttempts >= 8 || loginCount >= 120 || authenticating >= 2) {
      throw new HttpError(429, 'login_throttled');
    }
    loginCount += 1;
    attempts.set(username, previousAttempts + 1);

    authenticating += 1;
    let valid;
    let user;
    try {
      user = store.findUser(username);
      valid = await verifyPassword(password, user?.password);
    } finally {
      authenticating -= 1;
    }
    if (!valid || !user) {
      counts.invalidLogins += 1;
      event('login_denied', requestId);
      throw new HttpError(401, 'invalid_credentials');
    }
    attempts.delete(username);
    const previous = sessionToken(req.headers.cookie);
    const token = newToken();
    store.createSession(digest(key, 'session', token), user.id, Math.floor(now / 1000),
      previous && digest(key, 'session', previous));
    event('login_accepted', requestId, { actor_id: user.id });
    return send(res, 200, { username: user.username, role: user.role, csrf: digest(key, 'csrf', token) },
      { 'set-cookie': sessionCookie(token) });
  }

  async function handle(req, res) {
    const requestId = randomUUID();
    const started = clock();
    counts.requests += 1;
    for (const [key, value] of Object.entries(securityHeaders)) res.setHeader(key, value);
    res.setHeader('x-request-id', requestId);
    let route = 'unmatched';

    try {
      if (!req.url?.startsWith('/') || !['GET', 'POST', 'PATCH', 'DELETE'].includes(req.method)) {
        throw new HttpError(405, 'method_denied');
      }
      if (!URL.canParse(req.url, origin)) throw new HttpError(400, 'invalid_target');
      const path = new URL(req.url, origin);
      if (path.origin !== origin) throw new HttpError(400, 'invalid_target');
      const pathname = path.pathname;
      const asset = assets.get(pathname);
      if (asset && req.method === 'GET') {
        route = 'frontend';
        res.writeHead(200, { 'content-type': asset.type });
        return res.end(asset.data);
      }
      if (req.method === 'GET' && ['/healthz', '/readyz'].includes(pathname)) {
        route = pathname.slice(1);
        if (pathname === '/readyz') store.ready();
        return send(res, 200, { status: 'ok' });
      }
      if (pathname === '/api/session') {
        route = 'session';
        if (req.method === 'POST') return await login(req, res, requestId);
        if (req.method === 'GET') {
          const { user, csrf } = authenticate(req);
          return send(res, 200, { username: user.username, role: user.role, csrf });
        }
        if (req.method === 'DELETE') {
          const { user, sessionDigest } = authorize(req);
          store.deleteSession(sessionDigest);
          event('logout', requestId, { actor_id: user.id });
          return send(res, 204, undefined, { 'set-cookie': sessionCookie(null) });
        }
      }
      if (pathname === '/api/findings' && req.method === 'GET') {
        route = 'findings_list';
        authenticate(req);
        const cursor = path.searchParams.get('after') ?? '0';
        if (!/^\d{1,15}$/.test(cursor)) throw new HttpError(400, 'invalid_cursor');
        const findings = store.listFindings(Number(cursor));
        return send(res, 200, {
          findings, next: findings.length === 100 ? findings.at(-1).id : null,
        });
      }
      if (pathname === '/api/findings' && req.method === 'POST') {
        route = 'findings_create';
        const { user } = authorize(req, 'admin');
        const { title, severity } = await jsonBody(req, ['title', 'severity']);
        if (typeof title !== 'string' || title.trim().length < 4 || title.trim().length > 120 ||
            /[\u0000-\u001f\u007f]/u.test(title) || !severities.includes(severity)) {
          throw new HttpError(400, 'invalid_finding');
        }
        const finding = store.insertFinding(title.trim(), severity, user.id);
        counts.changes += 1;
        event('finding_created', requestId, { actor_id: user.id, finding_id: finding.id, severity });
        return send(res, 201, finding);
      }
      const match = /^\/api\/findings\/([1-9]\d{0,14})$/.exec(pathname);
      if (match && req.method === 'PATCH') {
        route = 'findings_update';
        const { user } = authorize(req, 'admin');
        const { status } = await jsonBody(req, ['status']);
        if (!statuses.includes(status)) throw new HttpError(400, 'invalid_status');
        const finding = store.updateFinding(Number(match[1]), status, user.id);
        if (!finding) throw new HttpError(404, 'not_found');
        counts.changes += 1;
        event('finding_updated', requestId, { actor_id: user.id, finding_id: finding.id, status });
        return send(res, 200, finding);
      }
      throw new HttpError(404, 'not_found');
    } catch (err) {
      if (err instanceof HttpError) {
        const headers = err.status === 413 ? { connection: 'close' } : {};
        if (err.status === 429) headers['retry-after'] = 60;
        return send(res, err.status, { error: err.message }, headers);
      }
      counts.errors += 1;
      event('request_error', requestId, { code: 'INTERNAL_ERROR' });
      return send(res, 500, { error: 'internal_error' });
    } finally {
      event('http_request', requestId, {
        route, status: res.statusCode, duration_ms: Math.max(0, clock() - started),
      });
    }
  }

  function metrics() {
    const output = [
      '# TYPE desk_http_requests_total counter',
      `desk_http_requests_total ${counts.requests}`,
      '# TYPE desk_http_errors_total counter',
      `desk_http_errors_total ${counts.errors}`,
      '# TYPE desk_login_denied_total counter',
      `desk_login_denied_total ${counts.invalidLogins}`,
      '# TYPE desk_remediation_changes_total counter',
      `desk_remediation_changes_total ${counts.changes}`,
      '# TYPE desk_findings gauge',
    ];
    const findings = new Map(store.findingCounts().map(
      ({ severity, status, count }) => [`${severity}:${status}`, count],
    ));
    for (const severity of severities) {
      for (const status of statuses) {
        const count = findings.get(`${severity}:${status}`) ?? 0;
        output.push(`desk_findings{severity="${severity}",status="${status}"} ${count}`);
      }
    }
    return `${output.join('\n')}\n`;
  }

  return { handle, metrics };
}
