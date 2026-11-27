import { DatabaseSync } from 'node:sqlite';

export const severities = Object.freeze(['critical', 'high', 'medium', 'low']);
export const statuses = Object.freeze(['open', 'in_progress', 'resolved']);
const sessionSeconds = 8 * 60 * 60;

export function openStore(path) {
  const db = new DatabaseSync(path);
  db.exec(`
    PRAGMA busy_timeout = 5000;
    PRAGMA foreign_keys = ON;
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY,
      username TEXT NOT NULL UNIQUE,
      role TEXT NOT NULL CHECK(role IN ('admin','viewer')),
      password TEXT NOT NULL
    ) STRICT;
    CREATE TABLE IF NOT EXISTS sessions (
      digest TEXT PRIMARY KEY,
      user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      expires INTEGER NOT NULL
    ) STRICT;
    CREATE INDEX IF NOT EXISTS sessions_expiration ON sessions(expires);
    CREATE TABLE IF NOT EXISTS findings (
      id INTEGER PRIMARY KEY,
      title TEXT NOT NULL CHECK(length(title) BETWEEN 4 AND 120),
      severity TEXT NOT NULL CHECK(severity IN ('critical','high','medium','low')),
      status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','in_progress','resolved')),
      updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_by INTEGER NOT NULL REFERENCES users(id)
    ) STRICT;
  `);

  const findUser = db.prepare('SELECT id, username, role, password FROM users WHERE username = ?');
  const insertUser = db.prepare(
    'INSERT INTO users(username, role, password) VALUES (?, ?, ?)',
  );
  const findSession = db.prepare(`
    SELECT users.id, users.username, users.role
    FROM sessions JOIN users ON users.id = sessions.user_id
    WHERE sessions.digest = ? AND sessions.expires > ?
  `);
  const deleteSession = db.prepare('DELETE FROM sessions WHERE digest = ?');
  const deleteExpired = db.prepare('DELETE FROM sessions WHERE expires <= ?');
  const insertSession = db.prepare('INSERT INTO sessions VALUES (?, ?, ?)');
  const listFindings = db.prepare(`
    SELECT id, title, severity, status, updated_at FROM findings
    WHERE id > ? ORDER BY id LIMIT 100
  `);
  const insertFinding = db.prepare(`
    INSERT INTO findings(title, severity, updated_by) VALUES (?, ?, ?)
    RETURNING id, title, severity, status, updated_at
  `);
  const updateFinding = db.prepare(`
    UPDATE findings SET status = ?, updated_by = ?,
      updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
    WHERE id = ? RETURNING id, title, severity, status, updated_at
  `);
  const findingCounts = db.prepare(`
    SELECT severity, status, count(*) AS count FROM findings GROUP BY severity, status
  `);

  return {
    findUser: (username) => findUser.get(username),
    insertUser: (username, role, hash) => insertUser.run(username, role, hash),
    findSession: (digest, now) => findSession.get(digest, now),
    deleteSession: (digest) => deleteSession.run(digest),
    createSession(digest, userId, now, previousDigest) {
      db.exec('BEGIN IMMEDIATE');
      try {
        deleteExpired.run(now);
        if (previousDigest) deleteSession.run(previousDigest);
        insertSession.run(digest, userId, now + sessionSeconds);
        db.exec('COMMIT');
      } catch (err) {
        db.exec('ROLLBACK');
        throw err;
      }
    },
    listFindings: (after) => listFindings.all(after),
    insertFinding: (title, severity, userId) => insertFinding.get(title, severity, userId),
    updateFinding: (id, status, userId) => updateFinding.get(status, userId, id),
    findingCounts: () => findingCounts.all(),
    ready: () => db.prepare('SELECT 1 FROM findings LIMIT 1').get(),
    close: () => db.close(),
  };
}

export function backupDatabase(path, target) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    db.exec('PRAGMA busy_timeout = 5000');
    db.prepare('VACUUM INTO ?').run(target);
  } finally {
    db.close();
  }
}

export function inspectBackup(path) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    if (db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok') {
      throw new Error('SQLite integrity check failed');
    }
    const result = db.prepare('SELECT count(*) AS findings FROM findings').get();
    return { findings: result.findings };
  } finally {
    db.close();
  }
}
