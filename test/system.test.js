import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { inflateRawSync } from 'node:zlib';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import { startServer, tempDir } from './helpers.js';

let pos;
let admin;
const dataDir = tempDir();

before(async () => {
  pos = await startServer({ AUTO_BACKUP: '0' }, dataDir);
  admin = await pos.login('admin', '1234');
});
after(() => pos.stop());

const raw = (url, token) => fetch(pos.base + url, { headers: { Authorization: `Bearer ${token}` } });

test('cashiers cannot use the system panel', async () => {
  await pos.call('POST', '/api/users', { username: 'kim', name: 'Kim', pin: '1357', role: 'cashier' }, admin);
  const cashier = await pos.login('kim', '1357');
  for (const url of ['/api/system/health', '/api/system/backups', '/api/system/sessions', '/api/system/export']) {
    assert.equal((await pos.call('GET', url, null, cashier)).status, 403, url);
  }
});

test('health reports counts and warns about the default PIN and missing backups', async () => {
  const h = (await pos.call('GET', '/api/system/health', null, admin)).data;
  assert.equal(h.database.schema_version, 2);
  assert.equal(h.database.counts.products, 9);
  assert.ok(h.warnings.some((w) => /PIN 1234: admin/.test(w)));
  assert.ok(h.warnings.some((w) => /no backups/.test(w)));
  assert.equal(h.stripe.configured, false);
});

test('backup: create, list, download, delete, and reject bad names', async () => {
  const made = (await pos.call('POST', '/api/system/backups', null, admin)).data;
  assert.match(made.name, /^pos-\d{8}-\d{6}\.db$/);
  const list = (await pos.call('GET', '/api/system/backups', null, admin)).data.backups;
  assert.equal(list[0].name, made.name);

  const file = await raw(`/api/system/backups/${made.name}`, admin);
  assert.equal(file.status, 200);
  const bytes = Buffer.from(await file.arrayBuffer());
  assert.equal(bytes.subarray(0, 15).toString(), 'SQLite format 3');

  // The backup is a working database with the same data.
  const copy = new DatabaseSync(path.join(dataDir, 'backups', made.name), { readOnly: true });
  assert.equal(copy.prepare('SELECT COUNT(*) AS n FROM products').get().n, 9);
  copy.close();

  assert.equal((await raw('/api/system/backups/..%2Fpos.db', admin)).status, 404);
  assert.equal((await raw('/api/system/backups/pos.db', admin)).status, 404);
  assert.equal((await pos.call('DELETE', `/api/system/backups/${made.name}`, null, admin)).status, 200);
  assert.equal((await pos.call('GET', '/api/system/backups', null, admin)).data.backups.length, 0);
});

test('sessions can be listed and ended', async () => {
  const other = await pos.login('admin', '1234');
  const list = (await pos.call('GET', '/api/system/sessions', null, admin)).data;
  assert.ok(list.length >= 2);
  const mine = list.find((s) => s.current);
  assert.equal((await pos.call('DELETE', `/api/system/sessions/${mine.sid}`, null, admin)).status, 400);

  const theirs = list.find((s) => !s.current);
  assert.equal((await pos.call('DELETE', `/api/system/sessions/${theirs.sid}`, null, admin)).status, 200);

  await pos.login('admin', '1234');
  const ended = (await pos.call('POST', '/api/system/sessions/end-others', null, admin)).data.ended;
  assert.ok(ended >= 1);
  assert.equal((await pos.call('GET', '/api/me', null, other)).status, 401);
  assert.equal((await pos.call('GET', '/api/me', null, admin)).status, 200, 'own session survives');
});

test('locked accounts can be unlocked', async () => {
  for (let i = 0; i < 5; i++) await pos.call('POST', '/api/login', { username: 'kim', pin: '0000' });
  assert.equal((await pos.call('POST', '/api/login', { username: 'kim', pin: '1357' })).status, 429);
  const sec = (await pos.call('GET', '/api/system/security', null, admin)).data;
  assert.ok(sec.locks.find((l) => l.username === 'kim').locked_until);
  assert.ok(sec.failed_logins.length >= 5);
  assert.equal((await pos.call('DELETE', '/api/system/locks/kim', null, admin)).status, 200);
  assert.equal((await pos.call('POST', '/api/login', { username: 'kim', pin: '1357' })).status, 200);
});

test('full export is a valid ZIP of CSV files without PIN hashes', async () => {
  const res = await raw('/api/system/export', admin);
  assert.equal(res.headers.get('content-type'), 'application/zip');
  const zipped = Buffer.from(await res.arrayBuffer());
  assert.equal(zipped.readUInt32LE(0), 0x04034b50);

  // Walk the local file headers and inflate every entry.
  const files = {};
  let at = 0;
  while (zipped.readUInt32LE(at) === 0x04034b50) {
    const size = zipped.readUInt32LE(at + 18);
    const nameLen = zipped.readUInt16LE(at + 26);
    const name = zipped.subarray(at + 30, at + 30 + nameLen).toString();
    const start = at + 30 + nameLen;
    files[name] = inflateRawSync(zipped.subarray(start, start + size)).toString('utf8');
    at = start + size;
  }
  assert.match(files['README.txt'], /Full data export/);
  assert.match(files['products.csv'], /Cola 330 ml/);
  assert.match(files['users.csv'], /admin/);
  assert.doesNotMatch(files['users.csv'], /pin_hash/);
  assert.ok(files['sales.csv'] && files['audit_log.csv']);
});

test('integrity check passes, then catches a tampered stock level', async () => {
  await pos.call('POST', '/api/shifts', { opening_float: 0 }, admin);
  const cola = (await pos.call('GET', '/api/products', null, admin)).data.find((p) => p.sku === 'DRK-001');
  await pos.call('POST', '/api/sales', { items: [{ product_id: cola.id, qty: 2 }], payment_method: 'cash', tendered: 500 }, admin);

  const good = (await pos.call('POST', '/api/system/integrity', null, admin)).data;
  assert.equal(good.ok, true, JSON.stringify(good.checks.filter((c) => !c.ok)));

  const db = new DatabaseSync(path.join(dataDir, 'pos.db'));
  db.prepare('UPDATE products SET stock = stock + 5 WHERE id = ?').run(cola.id);
  db.close();
  const bad = (await pos.call('POST', '/api/system/integrity', null, admin)).data;
  assert.equal(bad.ok, false);
  const stock = bad.checks.find((c) => c.name === 'Stock levels');
  assert.equal(stock.ok, false);
  assert.match(stock.issues[0], /DRK-001/);
});

test('demo data removal deletes unsold demo products and switches off sold ones', async () => {
  const before = (await pos.call('GET', '/api/system/demo', null, admin)).data;
  assert.equal(before.length, 9);
  assert.equal(before.find((p) => p.sku === 'DRK-001').action, 'deactivate');
  const r = (await pos.call('POST', '/api/system/demo/clear', null, admin)).data;
  assert.deepEqual(r, { deleted: 8, deactivated: 1, categories_deleted: 2 });
  assert.equal((await pos.call('GET', '/api/products', null, admin)).data.length, 0);
  assert.equal((await pos.call('GET', '/api/system/demo', null, admin)).data.length, 1, 'sold product kept for receipts');
  const sale = (await pos.call('GET', '/api/sales/1', null, admin)).data;
  assert.equal(sale.items[0].name, 'Cola 330 ml');
});
