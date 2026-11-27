import { createHmac, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';

const derive = promisify(scrypt);
const settings = { N: 32768, r: 8, p: 3, maxmem: 64 * 1024 * 1024 };
const dummyHash = `${'0'.repeat(32)}:${'0'.repeat(64)}`;
const cookieName = '__Host-lab_session';
const maxAge = 8 * 60 * 60;

export function validUsername(username) {
  return typeof username === 'string' && /^[a-z][a-z0-9_-]{2,31}$/.test(username);
}

export function validPassword(password) {
  return typeof password === 'string' && password.length >= 16 &&
    Buffer.byteLength(password) <= 128;
}

export async function passwordHash(password) {
  const salt = randomBytes(16);
  const hash = await derive(password, salt, 32, settings);
  return `${salt.toString('hex')}:${hash.toString('hex')}`;
}

export async function verifyPassword(password, stored = dummyHash) {
  const [salt, expected] = stored.split(':').map((value) => Buffer.from(value, 'hex'));
  const supplied = await derive(password, salt, 32, settings);
  return timingSafeEqual(supplied, expected);
}

export function newToken() {
  return randomBytes(32).toString('base64url');
}

export function digest(key, scope, token) {
  return createHmac('sha256', key).update(scope).update('\0').update(token).digest('hex');
}

export function safeEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function sessionToken(cookieHeader = '') {
  const sessions = cookieHeader.split(';').map((piece) => piece.trim()).filter(
    (piece) => piece.startsWith(`${cookieName}=`),
  );
  if (sessions.length !== 1) return null;
  const value = sessions[0].slice(cookieName.length + 1);
  return /^[A-Za-z0-9_-]{43}$/.test(value) ? value : null;
}

export function sessionCookie(token) {
  return `${cookieName}=${token ?? ''}; Path=/; Max-Age=${token ? maxAge : 0}; Secure; HttpOnly; SameSite=Strict`;
}
