import { mkdirSync, readdirSync, statSync, existsSync, unlinkSync } from 'node:fs';
import path from 'node:path';
import { db, DATA_DIR } from './db.js';

export const BACKUP_DIR = path.join(DATA_DIR, 'backups');
export const AUTO_KEEP = 14;
const NAME_RE = /^pos-\d{8}-\d{6}(-auto)?\.db$/;

const stamp = (d) => d.toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);

function info(name) {
  const st = statSync(path.join(BACKUP_DIR, name));
  return { name, size: st.size, created_at: st.mtime.toISOString(), auto: name.includes('-auto') };
}

// VACUUM INTO writes a consistent, compacted copy while the POS keeps running.
export function createBackup(auto = false) {
  mkdirSync(BACKUP_DIR, { recursive: true });
  const name = `pos-${stamp(new Date())}${auto ? '-auto' : ''}.db`;
  const file = path.join(BACKUP_DIR, name);
  if (existsSync(file)) throw Object.assign(new Error('A backup was made in the last second. Try again.'), { status: 409 });
  db.exec(`VACUUM INTO '${file.replace(/'/g, "''")}'`);
  return info(name);
}

export function listBackups() {
  if (!existsSync(BACKUP_DIR)) return [];
  return readdirSync(BACKUP_DIR).filter((n) => NAME_RE.test(n)).map(info)
    .sort((a, b) => b.name.localeCompare(a.name));
}

export function backupFile(name) {
  if (!NAME_RE.test(name)) return null;
  const file = path.join(BACKUP_DIR, name);
  return existsSync(file) ? file : null;
}

export function deleteBackup(name) {
  const file = backupFile(name);
  if (!file) return false;
  unlinkSync(file);
  return true;
}

// Keeps the newest automatic backups. Manual backups are never removed automatically.
export function pruneAutoBackups(keep = AUTO_KEEP) {
  const autos = listBackups().filter((b) => b.auto);
  for (const b of autos.slice(keep)) deleteBackup(b.name);
}

export function autoBackupDue(hours = 24) {
  const last = listBackups().find((b) => b.auto);
  return !last || Date.now() - Date.parse(last.created_at) > hours * 3600_000;
}
