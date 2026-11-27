import { existsSync, readFileSync } from 'node:fs';
import process from 'node:process';
import { passwordHash, validPassword, validUsername } from './auth.mjs';
import { backupDatabase, inspectBackup, openStore } from './store.mjs';

process.umask(0o077);
const [command, arg, role] = process.argv.slice(2);
const path = process.env.DB_PATH;
try {
  if (command === 'user' && path && validUsername(arg) && ['admin', 'viewer'].includes(role)) {
    const password = readFileSync(0, 'utf8').replace(/\r?\n$/, '');
    if (!validPassword(password)) throw new Error('Password must have 16 characters and at most 128 bytes');
    const hash = await passwordHash(password);
    const store = openStore(path);
    try {
      store.insertUser(arg, role, hash);
      console.log(JSON.stringify({ event: 'user_created', role }));
    } finally {
      store.close();
    }
  } else if (command === 'backup' && path && arg && !existsSync(arg)) {
    backupDatabase(path, arg);
    console.log(JSON.stringify({ event: 'backup_completed', ...inspectBackup(arg) }));
  } else if (command === 'inspect' && arg) {
    console.log(JSON.stringify({ event: 'backup_verified', ...inspectBackup(arg) }));
  } else {
    throw new Error('Use user <username> <admin|viewer> (password via stdin), backup <new-file>, or inspect <file>');
  }
} catch (err) {
  console.error(JSON.stringify({ event: 'cli_failed', code: err.code ?? 'INPUT_OR_STATE' }));
  process.exitCode = 1;
}
