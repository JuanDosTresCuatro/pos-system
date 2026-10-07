// Checks that a database created by version 1 (refunds stored on the sale) upgrades cleanly.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import { startServer, tempDir } from './helpers.js';

test('version 1 database migrates refunds into the refunds table', async () => {
  const dir = tempDir();
  const old = new DatabaseSync(path.join(dir, 'pos.db'));
  old.exec(`
    CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE COLLATE NOCASE, name TEXT NOT NULL,
      pin_hash TEXT NOT NULL, role TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL);
    CREATE TABLE sales (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), created_at TEXT NOT NULL,
      subtotal INTEGER NOT NULL, discount_pct REAL NOT NULL DEFAULT 0, discount INTEGER NOT NULL DEFAULT 0, tax INTEGER NOT NULL,
      total INTEGER NOT NULL, tax_inclusive INTEGER NOT NULL, payment_method TEXT NOT NULL CHECK (payment_method IN ('cash', 'card')),
      tendered INTEGER NOT NULL, change_due INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'refunded')),
      refunded_at TEXT, refunded_by INTEGER REFERENCES users(id), refund_reason TEXT);
    CREATE INDEX idx_sales_refunded ON sales(refunded_at);
    CREATE TABLE sale_items (id INTEGER PRIMARY KEY, sale_id INTEGER NOT NULL REFERENCES sales(id), product_id INTEGER,
      sku TEXT NOT NULL, name TEXT NOT NULL, unit_price INTEGER NOT NULL, unit_cost INTEGER NOT NULL DEFAULT 0, qty INTEGER NOT NULL,
      discount INTEGER NOT NULL DEFAULT 0, tax_rate REAL NOT NULL, tax INTEGER NOT NULL, total INTEGER NOT NULL);
    INSERT INTO users VALUES (1, 'admin', 'Manager', 'x:y', 'admin', 1, '2026-01-01T00:00:00Z');
    INSERT INTO sales VALUES (1, 1, '2026-01-02T10:00:00Z', 240, 0, 0, 40, 240, 1, 'cash', 300, 60, 'completed', NULL, NULL, NULL);
    INSERT INTO sales VALUES (2, 1, '2026-01-02T11:00:00Z', 395, 0, 0, 0, 395, 1, 'card', 395, 0, 'refunded', '2026-01-02T12:00:00Z', 1, 'stale');
    INSERT INTO sale_items VALUES (1, 1, NULL, 'DRK-001', 'Cola', 120, 45, 2, 0, 20, 40, 240);
    INSERT INTO sale_items VALUES (2, 2, NULL, 'FD-001', 'Sandwich', 395, 150, 1, 0, 0, 0, 395);
  `);
  old.close();

  const pos = await startServer({ SEED_DEMO: '0' }, dir);
  try {
    const db = new DatabaseSync(path.join(dir, 'pos.db'));
    assert.equal(db.prepare('PRAGMA user_version').get().user_version, 2);
    const s2 = db.prepare('SELECT * FROM sales WHERE id = 2').get();
    assert.equal(s2.status, 'refunded');
    assert.equal(s2.refunded_amount, 395);
    const refund = db.prepare('SELECT * FROM refunds WHERE sale_id = 2').get();
    assert.equal(refund.amount, 395);
    assert.equal(refund.reason, 'stale');
    assert.equal(db.prepare('SELECT refunded_qty FROM sale_items WHERE id = 2').get().refunded_qty, 1);
    assert.equal(db.prepare('SELECT status FROM sales WHERE id = 1').get().status, 'completed');
    assert.equal(db.prepare('PRAGMA foreign_key_check').all().length, 0);
    db.close();
  } finally {
    pos.stop();
  }
});
