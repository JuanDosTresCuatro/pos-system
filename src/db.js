import { DatabaseSync } from 'node:sqlite';
import { scryptSync, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const DATA_DIR = path.resolve(process.env.POS_DATA_DIR || path.join(ROOT, 'data'));
export const DB_PATH = path.join(DATA_DIR, 'pos.db');
mkdirSync(DATA_DIR, { recursive: true });

export const db = new DatabaseSync(DB_PATH);
db.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;');

const SCHEMA_VERSION = 2;

db.exec(`
CREATE TABLE IF NOT EXISTS settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS users (
  id         INTEGER PRIMARY KEY,
  username   TEXT NOT NULL UNIQUE COLLATE NOCASE,
  name       TEXT NOT NULL,
  pin_hash   TEXT NOT NULL,
  role       TEXT NOT NULL CHECK (role IN ('admin', 'cashier')),
  active     INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS categories (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE COLLATE NOCASE
);
CREATE TABLE IF NOT EXISTS products (
  id          INTEGER PRIMARY KEY,
  sku         TEXT NOT NULL UNIQUE COLLATE NOCASE,
  barcode     TEXT UNIQUE,
  name        TEXT NOT NULL,
  category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
  price       INTEGER NOT NULL CHECK (price >= 0),
  cost        INTEGER NOT NULL DEFAULT 0 CHECK (cost >= 0),
  tax_rate    REAL NOT NULL DEFAULT 0,
  stock       INTEGER NOT NULL DEFAULT 0,
  track_stock INTEGER NOT NULL DEFAULT 1,
  low_stock   INTEGER NOT NULL DEFAULT 5,
  active      INTEGER NOT NULL DEFAULT 1,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS shifts (
  id            INTEGER PRIMARY KEY,
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  opened_by     INTEGER NOT NULL REFERENCES users(id),
  opened_at     TEXT NOT NULL,
  opening_float INTEGER NOT NULL DEFAULT 0,
  closed_by     INTEGER REFERENCES users(id),
  closed_at     TEXT,
  expected_cash INTEGER,
  counted_cash  INTEGER,
  notes         TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_one_open_shift ON shifts(status) WHERE status = 'open';
CREATE TABLE IF NOT EXISTS cash_movements (
  id         INTEGER PRIMARY KEY,
  shift_id   INTEGER NOT NULL REFERENCES shifts(id),
  user_id    INTEGER NOT NULL REFERENCES users(id),
  type       TEXT NOT NULL CHECK (type IN ('paid_in', 'paid_out')),
  amount     INTEGER NOT NULL CHECK (amount > 0),
  reason     TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sales (
  id                    INTEGER PRIMARY KEY,
  user_id               INTEGER NOT NULL REFERENCES users(id),
  shift_id              INTEGER REFERENCES shifts(id),
  created_at            TEXT NOT NULL,
  subtotal              INTEGER NOT NULL,
  discount_pct          REAL NOT NULL DEFAULT 0,
  discount              INTEGER NOT NULL DEFAULT 0,
  tax                   INTEGER NOT NULL,
  total                 INTEGER NOT NULL,
  tax_inclusive         INTEGER NOT NULL,
  payment_method        TEXT NOT NULL CHECK (payment_method IN ('cash', 'card')),
  tendered              INTEGER NOT NULL,
  change_due            INTEGER NOT NULL DEFAULT 0,
  status                TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'partially_refunded', 'refunded')),
  refunded_amount       INTEGER NOT NULL DEFAULT 0,
  stripe_payment_intent TEXT,
  card_brand            TEXT,
  card_last4            TEXT,
  card_read_method      TEXT,
  card_app_name         TEXT,
  card_aid              TEXT,
  card_auth_code        TEXT
);
CREATE TABLE IF NOT EXISTS sale_items (
  id              INTEGER PRIMARY KEY,
  sale_id         INTEGER NOT NULL REFERENCES sales(id),
  product_id      INTEGER REFERENCES products(id),
  sku             TEXT NOT NULL,
  name            TEXT NOT NULL,
  unit_price      INTEGER NOT NULL,
  unit_cost       INTEGER NOT NULL DEFAULT 0,
  qty             INTEGER NOT NULL,
  discount        INTEGER NOT NULL DEFAULT 0,
  tax_rate        REAL NOT NULL,
  tax             INTEGER NOT NULL,
  total           INTEGER NOT NULL,
  refunded_qty    INTEGER NOT NULL DEFAULT 0,
  refunded_amount INTEGER NOT NULL DEFAULT 0,
  refunded_tax    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_sale_items_sale ON sale_items(sale_id);
CREATE TABLE IF NOT EXISTS refunds (
  id              INTEGER PRIMARY KEY,
  sale_id         INTEGER NOT NULL REFERENCES sales(id),
  user_id         INTEGER REFERENCES users(id),
  shift_id        INTEGER REFERENCES shifts(id),
  created_at      TEXT NOT NULL,
  reason          TEXT NOT NULL,
  method          TEXT NOT NULL CHECK (method IN ('cash', 'card', 'stripe')),
  amount          INTEGER NOT NULL,
  tax             INTEGER NOT NULL,
  restocked       INTEGER NOT NULL DEFAULT 0,
  provider_ref    TEXT,
  provider_status TEXT
);
CREATE INDEX IF NOT EXISTS idx_refunds_sale ON refunds(sale_id);
CREATE INDEX IF NOT EXISTS idx_refunds_created ON refunds(created_at);
CREATE TABLE IF NOT EXISTS refund_items (
  id           INTEGER PRIMARY KEY,
  refund_id    INTEGER NOT NULL REFERENCES refunds(id),
  sale_item_id INTEGER NOT NULL REFERENCES sale_items(id),
  qty          INTEGER NOT NULL,
  amount       INTEGER NOT NULL,
  tax          INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS card_payments (
  id              INTEGER PRIMARY KEY,
  user_id         INTEGER NOT NULL REFERENCES users(id),
  shift_id        INTEGER REFERENCES shifts(id),
  reader_id       TEXT NOT NULL,
  payment_intent  TEXT,
  amount          INTEGER NOT NULL,
  currency        TEXT NOT NULL,
  cart            TEXT NOT NULL,
  status          TEXT NOT NULL CHECK (status IN ('starting', 'waiting', 'declined', 'succeeded', 'canceled', 'error')),
  message         TEXT,
  sale_id         INTEGER REFERENCES sales(id),
  created_at      TEXT NOT NULL,
  updated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_card_payments_status ON card_payments(status);
CREATE TABLE IF NOT EXISTS stock_movements (
  id         INTEGER PRIMARY KEY,
  product_id INTEGER NOT NULL REFERENCES products(id),
  change     INTEGER NOT NULL,
  reason     TEXT NOT NULL,
  note       TEXT,
  sale_id    INTEGER REFERENCES sales(id),
  user_id    INTEGER REFERENCES users(id),
  created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit_log (
  id         INTEGER PRIMARY KEY,
  user_id    INTEGER REFERENCES users(id),
  action     TEXT NOT NULL,
  detail     TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at);
`);

export const DEFAULT_SETTINGS = {
  store_name: 'My Store',
  store_address: '',
  tax_number: '',
  tax_label: 'VAT',
  currency: 'GBP',
  locale: 'en-GB',
  tax_inclusive: '1',
  default_tax_rate: '20',
  max_cashier_discount: '10',
  allow_negative_stock: '0',
  receipt_footer: 'Thank you for your custom',
  card_mode: 'manual',
  stripe_reader_id: '',
};

export const now = () => new Date().toISOString();

export function tx(fn) {
  db.exec('BEGIN IMMEDIATE');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }
}

// ---------- migrations
const columns = (table) => db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name);

function addColumn(table, name, definition) {
  if (!columns(table).includes(name)) db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${definition}`);
}

// Version 1 kept full refunds as columns on `sales` with a two-value status check.
// Version 2 moves them to `refunds` so partial refunds and card refunds can be recorded.
function migrateToV2() {
  addColumn('sale_items', 'refunded_qty', 'INTEGER NOT NULL DEFAULT 0');
  addColumn('sale_items', 'refunded_amount', 'INTEGER NOT NULL DEFAULT 0');
  addColumn('sale_items', 'refunded_tax', 'INTEGER NOT NULL DEFAULT 0');
  if (!columns('sales').includes('refund_reason')) return;

  console.log('Migrating database to schema version 2 (refunds and till shifts)...');
  db.exec('PRAGMA foreign_keys = OFF');
  try {
    tx(() => {
      db.exec(`CREATE TABLE sales_v2 (
        id                    INTEGER PRIMARY KEY,
        user_id               INTEGER NOT NULL REFERENCES users(id),
        shift_id              INTEGER REFERENCES shifts(id),
        created_at            TEXT NOT NULL,
        subtotal              INTEGER NOT NULL,
        discount_pct          REAL NOT NULL DEFAULT 0,
        discount              INTEGER NOT NULL DEFAULT 0,
        tax                   INTEGER NOT NULL,
        total                 INTEGER NOT NULL,
        tax_inclusive         INTEGER NOT NULL,
        payment_method        TEXT NOT NULL CHECK (payment_method IN ('cash', 'card')),
        tendered              INTEGER NOT NULL,
        change_due            INTEGER NOT NULL DEFAULT 0,
        status                TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'partially_refunded', 'refunded')),
        refunded_amount       INTEGER NOT NULL DEFAULT 0,
        stripe_payment_intent TEXT,
        card_brand            TEXT,
        card_last4            TEXT,
        card_read_method      TEXT,
        card_app_name         TEXT,
        card_aid              TEXT,
        card_auth_code        TEXT
      )`);
      db.exec(`INSERT INTO sales_v2 (id, user_id, created_at, subtotal, discount_pct, discount, tax, total, tax_inclusive,
          payment_method, tendered, change_due, status, refunded_amount)
        SELECT id, user_id, created_at, subtotal, discount_pct, discount, tax, total, tax_inclusive,
          payment_method, tendered, change_due, status, CASE WHEN status = 'refunded' THEN total ELSE 0 END FROM sales`);
      db.exec(`INSERT INTO refunds (sale_id, user_id, created_at, reason, method, amount, tax, restocked)
        SELECT id, refunded_by, refunded_at, COALESCE(refund_reason, ''), payment_method, total, tax, 1
        FROM sales WHERE status = 'refunded'`);
      db.exec(`INSERT INTO refund_items (refund_id, sale_item_id, qty, amount, tax)
        SELECT r.id, i.id, i.qty, i.total, i.tax FROM refunds r JOIN sale_items i ON i.sale_id = r.sale_id`);
      db.exec(`UPDATE sale_items SET refunded_qty = qty, refunded_amount = total, refunded_tax = tax
        WHERE sale_id IN (SELECT id FROM sales WHERE status = 'refunded')`);
      db.exec('DROP TABLE sales');
      db.exec('ALTER TABLE sales_v2 RENAME TO sales');
      const broken = db.prepare('PRAGMA foreign_key_check').all();
      if (broken.length) throw new Error(`Migration left ${broken.length} broken references`);
    });
  } finally {
    db.exec('PRAGMA foreign_keys = ON');
  }
}

if (db.prepare('PRAGMA user_version').get().user_version < SCHEMA_VERSION) {
  migrateToV2();
  db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
}
db.exec(`
CREATE INDEX IF NOT EXISTS idx_sales_created ON sales(created_at);
CREATE INDEX IF NOT EXISTS idx_sales_shift ON sales(shift_id);
`);

// ---------- helpers
export function hashPin(pin) {
  const salt = randomBytes(16);
  return `${salt.toString('hex')}:${scryptSync(String(pin), salt, 32).toString('hex')}`;
}

export function verifyPin(pin, stored) {
  const [salt, hash] = String(stored).split(':');
  if (!salt || !hash) return false;
  const actual = scryptSync(String(pin), Buffer.from(salt, 'hex'), 32);
  const expected = Buffer.from(hash, 'hex');
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export function getSettings() {
  const out = { ...DEFAULT_SETTINGS };
  for (const row of db.prepare('SELECT key, value FROM settings').all()) {
    if (row.key in DEFAULT_SETTINGS) out[row.key] = row.value;
  }
  return out;
}

export function saveSetting(key, value) {
  db.prepare('INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value')
    .run(key, String(value));
}

export function audit(userId, action, detail = '') {
  db.prepare('INSERT INTO audit_log (user_id, action, detail, created_at) VALUES (?, ?, ?, ?)')
    .run(userId ?? null, action, typeof detail === 'string' ? detail : JSON.stringify(detail), now());
}

// Demo catalogue loaded on first start. [sku, barcode, name, price, cost, tax rate, stock]
export const DEMO_CATALOGUE = {
  Drinks: [['DRK-001', '5000112637922', 'Cola 330 ml', 120, 45, 20, 48], ['DRK-002', '5010102112345', 'Still water 500 ml', 100, 25, 0, 60], ['DRK-003', '', 'Flat white', 320, 60, 20, 0], ['DRK-004', '', 'Tea', 220, 15, 20, 0]],
  Food: [['FD-001', '5000168001234', 'Cheese sandwich', 395, 150, 0, 12], ['FD-002', '', 'Croissant', 245, 70, 0, 20], ['FD-003', '5000328123456', 'Crisps 40 g', 110, 40, 20, 36]],
  Household: [['HH-001', '5011417567890', 'AA batteries (4)', 499, 210, 20, 15], ['HH-002', '', 'Phone charger USB-C', 1299, 480, 20, 4]],
};

// ---------- first-run seed
const insertSetting = db.prepare('INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)');
for (const [k, v] of Object.entries(DEFAULT_SETTINGS)) insertSetting.run(k, v);

if (db.prepare('SELECT COUNT(*) AS n FROM users').get().n === 0) {
  db.prepare('INSERT INTO users (username, name, pin_hash, role, created_at) VALUES (?, ?, ?, ?, ?)')
    .run('admin', 'Manager', hashPin('1234'), 'admin', now());
  console.log('Created default manager account: username "admin", PIN "1234". Change this PIN now.');
}

if (process.env.SEED_DEMO !== '0' && !db.prepare("SELECT 1 FROM settings WHERE key = 'demo_seeded'").get()) {
  tx(() => {
    const addCat = db.prepare('INSERT INTO categories (name) VALUES (?)');
    const addProd = db.prepare(`INSERT INTO products (sku, barcode, name, category_id, price, cost, tax_rate, stock, track_stock, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
    const addMove = db.prepare("INSERT INTO stock_movements (product_id, change, reason, created_at) VALUES (?, ?, 'initial', ?)");
    const t = now();
    for (const [cat, items] of Object.entries(DEMO_CATALOGUE)) {
      const catId = addCat.run(cat).lastInsertRowid;
      for (const [sku, barcode, name, price, cost, rate, stock] of items) {
        // Made-to-order items (stock 0 in the seed) are not stock-tracked.
        const tracked = stock > 0 ? 1 : 0;
        const id = addProd.run(sku, barcode || null, name, catId, price, cost, rate, stock, tracked, t, t).lastInsertRowid;
        if (tracked) addMove.run(id, stock, t);
      }
    }
    saveSetting('demo_seeded', '1');
  });
}
