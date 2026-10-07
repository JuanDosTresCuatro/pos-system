import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { readFileSync, statSync, statfsSync, existsSync } from 'node:fs';
import os from 'node:os';
import { randomBytes, randomUUID } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { db, tx, now, hashPin, verifyPin, getSettings, saveSetting, audit, DEFAULT_SETTINGS, DATA_DIR, DB_PATH, DEMO_CATALOGUE } from './src/db.js';
import { createBackup, listBackups, backupFile, deleteBackup, pruneAutoBackups, autoBackupDue, AUTO_KEEP, BACKUP_DIR } from './src/backup.js';
import { runIntegrityChecks } from './src/integrity.js';
import { zip } from './src/zip.js';
import * as stripe from './src/stripe.js';
import { priceLines } from './public/js/pricing.js';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(ROOT, 'public');
const PORT = Number(process.env.PORT) || 3000;
const HOST = process.env.HOST || '127.0.0.1';

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:",
};

// ---------- recent server errors (shown in System > Health)
const STARTED_AT = new Date();
const recentErrors = [];
function logError(context, err) {
  console.error(context, err);
  recentErrors.unshift({ at: now(), context, message: err?.message || String(err) });
  if (recentErrors.length > 50) recentErrors.length = 50;
}

// ---------- validation helpers
class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
class Raw {
  constructor(body, headers) { this.body = body; this.headers = headers; }
}
const bad = (msg) => new HttpError(400, msg);

function str(v, name, { max = 200, required = true } = {}) {
  const s = (v ?? '').toString().trim();
  if (required && !s) throw bad(`${name} is required`);
  if (s.length > max) throw bad(`${name} must be ${max} characters or fewer`);
  return s;
}
function int(v, name, { min = -Infinity, max = Infinity } = {}) {
  const n = Number(v);
  if (v === '' || v === null || v === undefined || !Number.isInteger(n)) throw bad(`${name} must be a whole number`);
  if (n < min || n > max) throw bad(`${name} must be between ${min} and ${max}`);
  return n;
}
function num(v, name, { min = -Infinity, max = Infinity } = {}) {
  const n = Number(v);
  if (v === '' || v === null || v === undefined || !Number.isFinite(n)) throw bad(`${name} must be a number`);
  if (n < min || n > max) throw bad(`${name} must be between ${min} and ${max}`);
  return n;
}
const bool = (v) => (v === true || v === 1 || v === '1' || v === 'true' || v === 'on' ? 1 : 0);
const MAX_MONEY = 100_000_000_00;

function dateRange(query) {
  const parse = (v, name, fallback) => {
    if (!v) return fallback;
    const d = new Date(v);
    if (Number.isNaN(d.getTime())) throw bad(`${name} is not a valid date`);
    return d.toISOString();
  };
  return { $from: parse(query.get('from'), 'from', '0000'), $to: parse(query.get('to'), 'to', '9999') };
}

function uniqueError(err, msg) {
  if (/UNIQUE constraint failed/.test(err.message)) throw new HttpError(409, msg);
  throw err;
}

function minorDigits(settings) {
  try {
    return new Intl.NumberFormat(settings.locale, { style: 'currency', currency: settings.currency })
      .resolvedOptions().maximumFractionDigits;
  } catch { return 2; }
}

// ---------- sessions
const sessions = new Map(); // token -> { sid, userId, expires, createdAt, lastSeen, ip, agent }
const SESSION_MS = 12 * 60 * 60 * 1000;
const loginFailures = new Map(); // username -> { count, until }
const MAX_FAILURES = 5;
const LOCK_MS = 5 * 60 * 1000;

function authUser(req) {
  const m = /^Bearer ([a-f0-9]{64})$/.exec(req.headers.authorization || '');
  if (!m) return null;
  const s = sessions.get(m[1]);
  if (!s || s.expires < Date.now()) { sessions.delete(m[1]); return null; }
  const user = db.prepare('SELECT id, username, name, role, active FROM users WHERE id = ?').get(s.userId);
  if (!user || !user.active) { sessions.delete(m[1]); return null; }
  s.expires = Date.now() + SESSION_MS;
  s.lastSeen = Date.now();
  return { id: user.id, username: user.username, name: user.name, role: user.role, token: m[1] };
}

function endSessionsFor(userId, exceptToken) {
  for (const [token, s] of sessions) if (s.userId === userId && token !== exceptToken) sessions.delete(token);
}

const publicUser = ({ id, username, name, role }) => ({ id, username, name, role });

// ---------- routing
const routes = [];
function route(method, pattern, role, handler) {
  const re = new RegExp(`^${pattern.replace(/:(\w+)/g, '(?<$1>[^/]+)')}$`);
  routes.push({ method, re, role, handler });
}

// ---------- auth
route('GET', '/api/store', null, () => ({ store_name: getSettings().store_name }));

route('POST', '/api/login', null, ({ body, req }) => {
  const username = str(body.username, 'Username', { max: 50 }).toLowerCase();
  const pin = str(body.pin, 'PIN', { max: 12 });
  const f = loginFailures.get(username);
  if (f && f.until > Date.now()) throw new HttpError(429, 'Too many failed attempts. Try again in a few minutes.');
  const u = db.prepare('SELECT * FROM users WHERE username = ? AND active = 1').get(username);
  if (!u || !verifyPin(pin, u.pin_hash)) {
    const prev = f && !(f.until && f.until <= Date.now()) ? f.count : 0;
    const count = prev + 1;
    loginFailures.set(username, { count, until: count >= MAX_FAILURES ? Date.now() + LOCK_MS : 0 });
    audit(u?.id, 'login_failed', username);
    throw new HttpError(401, 'Wrong username or PIN');
  }
  loginFailures.delete(username);
  const token = randomBytes(32).toString('hex');
  sessions.set(token, {
    sid: randomBytes(6).toString('hex'), userId: u.id, expires: Date.now() + SESSION_MS, createdAt: Date.now(), lastSeen: Date.now(),
    ip: req.socket.remoteAddress || '', agent: String(req.headers['user-agent'] || '').slice(0, 300),
  });
  audit(u.id, 'login');
  return { token, user: publicUser(u), settings: getSettings() };
});

route('POST', '/api/logout', 'user', ({ user }) => {
  sessions.delete(user.token);
  audit(user.id, 'logout');
});

route('GET', '/api/me', 'user', ({ user }) => ({ user: publicUser(user), settings: getSettings() }));

route('POST', '/api/me/pin', 'user', ({ body, user }) => {
  const u = db.prepare('SELECT pin_hash FROM users WHERE id = ?').get(user.id);
  if (!verifyPin(str(body.current, 'Current PIN', { max: 12 }), u.pin_hash)) throw bad('Current PIN is wrong');
  const pin = str(body.pin, 'New PIN', { max: 12 });
  if (!/^\d{4,8}$/.test(pin)) throw bad('PIN must be 4 to 8 digits');
  db.prepare('UPDATE users SET pin_hash = ? WHERE id = ?').run(hashPin(pin), user.id);
  endSessionsFor(user.id, user.token);
  audit(user.id, 'pin_changed', 'own PIN');
});

// ---------- settings
const SETTING_RULES = {
  store_name: (v) => str(v, 'Store name', { max: 100 }),
  store_address: (v) => str(v, 'Address', { max: 300, required: false }),
  tax_number: (v) => str(v, 'Tax number', { max: 50, required: false }),
  tax_label: (v) => str(v, 'Tax label', { max: 20 }),
  currency: (v) => str(v, 'Currency', { max: 3 }).toUpperCase(),
  locale: (v) => str(v, 'Locale', { max: 20 }),
  tax_inclusive: (v) => String(bool(v)),
  default_tax_rate: (v) => String(num(v, 'Default tax rate', { min: 0, max: 100 })),
  max_cashier_discount: (v) => String(num(v, 'Maximum cashier discount', { min: 0, max: 100 })),
  allow_negative_stock: (v) => String(bool(v)),
  receipt_footer: (v) => str(v, 'Receipt footer', { max: 300, required: false }),
  card_mode: (v) => {
    if (!['manual', 'stripe'].includes(v)) throw bad('Card payment mode must be manual or stripe');
    return v;
  },
  stripe_reader_id: (v) => str(v, 'Default card reader', { max: 100, required: false }),
};

route('GET', '/api/settings', 'user', () => getSettings());

route('PUT', '/api/settings', 'admin', ({ body, user }) => {
  const current = getSettings();
  const next = { ...current };
  for (const [key, rule] of Object.entries(SETTING_RULES)) if (key in body) next[key] = rule(body[key]);
  try {
    new Intl.NumberFormat(next.locale, { style: 'currency', currency: next.currency });
  } catch {
    throw bad('Currency must be a 3-letter ISO code (e.g. GBP) and locale a valid tag (e.g. en-GB)');
  }
  const changed = Object.keys(DEFAULT_SETTINGS).filter((k) => next[k] !== current[k]);
  if (changed.length) {
    tx(() => {
      for (const k of changed) saveSetting(k, next[k]);
      audit(user.id, 'settings_changed', Object.fromEntries(changed.map((k) => [k, { from: current[k], to: next[k] }])));
    });
  }
  return getSettings();
});

// ---------- categories
route('GET', '/api/categories', 'user', () => db.prepare('SELECT * FROM categories ORDER BY name').all());

route('POST', '/api/categories', 'admin', ({ body, user }) => {
  const name = str(body.name, 'Category name', { max: 50 });
  try {
    const id = db.prepare('INSERT INTO categories (name) VALUES (?)').run(name).lastInsertRowid;
    audit(user.id, 'category_created', name);
    return { id, name };
  } catch (err) { uniqueError(err, 'A category with that name already exists'); }
});

route('DELETE', '/api/categories/:id', 'admin', ({ params, user }) => {
  const cat = db.prepare('SELECT * FROM categories WHERE id = ?').get(int(params.id, 'id'));
  if (!cat) throw new HttpError(404, 'Category not found');
  tx(() => {
    db.prepare('UPDATE products SET category_id = NULL WHERE category_id = ?').run(cat.id);
    db.prepare('DELETE FROM categories WHERE id = ?').run(cat.id);
    audit(user.id, 'category_deleted', cat.name);
  });
});

// ---------- products
const PRODUCT_SELECT = 'SELECT p.*, c.name AS category FROM products p LEFT JOIN categories c ON c.id = p.category_id';
const getProduct = (id) => db.prepare(`${PRODUCT_SELECT} WHERE p.id = ?`).get(id);

route('GET', '/api/products', 'user', ({ query }) => {
  const all = query.get('all') === '1' ? 1 : 0;
  return db.prepare(`${PRODUCT_SELECT} WHERE ($all = 1 OR p.active = 1) ORDER BY p.name COLLATE NOCASE`).all({ $all: all });
});

route('GET', '/api/products/lookup', 'user', ({ query }) => {
  const code = str(query.get('code'), 'Code', { max: 64 });
  const p = db.prepare(`${PRODUCT_SELECT} WHERE p.active = 1 AND (p.barcode = $code OR p.sku = $code)`).get({ $code: code });
  if (!p) throw new HttpError(404, 'No product matches that code');
  return p;
});

function productInput(body) {
  const categoryId = body.category_id === '' || body.category_id == null ? null : int(body.category_id, 'Category');
  if (categoryId !== null && !db.prepare('SELECT 1 FROM categories WHERE id = ?').get(categoryId)) throw bad('Category does not exist');
  return {
    $sku: str(body.sku, 'SKU', { max: 64 }),
    $barcode: str(body.barcode, 'Barcode', { max: 64, required: false }) || null,
    $name: str(body.name, 'Name', { max: 120 }),
    $category_id: categoryId,
    $price: int(body.price, 'Price', { min: 0, max: MAX_MONEY }),
    $cost: int(body.cost ?? 0, 'Cost', { min: 0, max: MAX_MONEY }),
    $tax_rate: num(body.tax_rate, 'Tax rate', { min: 0, max: 100 }),
    $track_stock: bool(body.track_stock),
    $low_stock: int(body.low_stock ?? 0, 'Low stock level', { min: 0, max: 1_000_000 }),
    $active: body.active === undefined ? 1 : bool(body.active),
  };
}

route('POST', '/api/products', 'admin', ({ body, user }) => {
  const p = productInput(body);
  const stock = int(body.stock ?? 0, 'Opening stock', { min: 0, max: 1_000_000 });
  const t = now();
  try {
    return tx(() => {
      const id = db.prepare(`INSERT INTO products (sku, barcode, name, category_id, price, cost, tax_rate, stock, track_stock, low_stock, active, created_at, updated_at)
        VALUES ($sku, $barcode, $name, $category_id, $price, $cost, $tax_rate, $stock, $track_stock, $low_stock, $active, $t, $t)`)
        .run({ ...p, $stock: stock, $t: t }).lastInsertRowid;
      if (stock) {
        db.prepare("INSERT INTO stock_movements (product_id, change, reason, user_id, created_at) VALUES (?, ?, 'initial', ?, ?)")
          .run(id, stock, user.id, t);
      }
      audit(user.id, 'product_created', { id, sku: p.$sku, name: p.$name, price: p.$price });
      return getProduct(id);
    });
  } catch (err) { uniqueError(err, 'SKU or barcode is already used by another product'); }
});

route('PUT', '/api/products/:id', 'admin', ({ params, body, user }) => {
  const before = getProduct(int(params.id, 'id'));
  if (!before) throw new HttpError(404, 'Product not found');
  const p = productInput(body);
  try {
    return tx(() => {
      db.prepare(`UPDATE products SET sku = $sku, barcode = $barcode, name = $name, category_id = $category_id, price = $price,
        cost = $cost, tax_rate = $tax_rate, track_stock = $track_stock, low_stock = $low_stock, active = $active, updated_at = $t WHERE id = $id`)
        .run({ ...p, $t: now(), $id: before.id });
      const changes = {};
      for (const k of ['sku', 'barcode', 'name', 'category_id', 'price', 'cost', 'tax_rate', 'track_stock', 'low_stock', 'active']) {
        if (before[k] !== p[`$${k}`]) changes[k] = { from: before[k], to: p[`$${k}`] };
      }
      if (Object.keys(changes).length) audit(user.id, 'product_updated', { id: before.id, sku: before.sku, changes });
      return getProduct(before.id);
    });
  } catch (err) { uniqueError(err, 'SKU or barcode is already used by another product'); }
});

const STOCK_REASONS = ['delivery', 'count', 'damaged', 'return', 'other'];

route('POST', '/api/products/:id/stock', 'admin', ({ params, body, user }) => {
  const p = getProduct(int(params.id, 'id'));
  if (!p) throw new HttpError(404, 'Product not found');
  const change = int(body.change, 'Quantity change', { min: -1_000_000, max: 1_000_000 });
  if (change === 0) throw bad('Quantity change cannot be zero');
  const reason = str(body.reason, 'Reason', { max: 20 });
  if (!STOCK_REASONS.includes(reason)) throw bad('Unknown stock adjustment reason');
  const note = str(body.note, 'Note', { max: 200, required: false });
  return tx(() => {
    db.prepare('UPDATE products SET stock = stock + ?, updated_at = ? WHERE id = ?').run(change, now(), p.id);
    db.prepare('INSERT INTO stock_movements (product_id, change, reason, note, user_id, created_at) VALUES (?, ?, ?, ?, ?, ?)')
      .run(p.id, change, reason, note || null, user.id, now());
    audit(user.id, 'stock_adjusted', { id: p.id, sku: p.sku, change, reason, note, from: p.stock, to: p.stock + change });
    return getProduct(p.id);
  });
});

route('GET', '/api/products/:id/movements', 'admin', ({ params }) =>
  db.prepare(`SELECT m.*, u.name AS user_name FROM stock_movements m LEFT JOIN users u ON u.id = m.user_id
    WHERE m.product_id = ? ORDER BY m.id DESC LIMIT 200`).all(int(params.id, 'id')));

// ---------- till shifts
const openShift = () => db.prepare("SELECT * FROM shifts WHERE status = 'open'").get();

function requireShift() {
  const shift = openShift();
  if (!shift) throw new HttpError(409, 'The till is closed. Open the till before taking or refunding cash.');
  return shift;
}

function shiftSummary(id) {
  const shift = db.prepare(`SELECT s.*, o.name AS opened_by_name, c.name AS closed_by_name FROM shifts s
    JOIN users o ON o.id = s.opened_by LEFT JOIN users c ON c.id = s.closed_by WHERE s.id = ?`).get(id);
  if (!shift) throw new HttpError(404, 'Till session not found');
  const sales = db.prepare(`SELECT payment_method AS method, COUNT(*) AS count, COALESCE(SUM(total), 0) AS total
    FROM sales WHERE shift_id = ? GROUP BY payment_method`).all(id);
  const refunds = db.prepare(`SELECT CASE method WHEN 'cash' THEN 'cash' ELSE 'card' END AS method, COUNT(*) AS count,
    COALESCE(SUM(amount), 0) AS total FROM refunds WHERE shift_id = ? GROUP BY 1`).all(id);
  const movements = db.prepare(`SELECT m.*, u.name AS user_name FROM cash_movements m JOIN users u ON u.id = m.user_id
    WHERE m.shift_id = ? ORDER BY m.id`).all(id);
  const pick = (rows, m) => rows.find((r) => r.method === m) || { count: 0, total: 0 };
  const paidIn = movements.filter((m) => m.type === 'paid_in').reduce((a, m) => a + m.amount, 0);
  const paidOut = movements.filter((m) => m.type === 'paid_out').reduce((a, m) => a + m.amount, 0);
  const cashSales = pick(sales, 'cash');
  const cashRefunds = pick(refunds, 'cash');
  const expected = shift.opening_float + cashSales.total - cashRefunds.total + paidIn - paidOut;
  return {
    ...shift,
    cash_sales: cashSales,
    card_sales: pick(sales, 'card'),
    cash_refunds: cashRefunds,
    card_refunds: pick(refunds, 'card'),
    paid_in: paidIn,
    paid_out: paidOut,
    movements,
    expected_cash: shift.status === 'closed' ? shift.expected_cash : expected,
    variance: shift.status === 'closed' ? shift.counted_cash - shift.expected_cash : null,
  };
}

// Cashiers count the drawer blind: they only see the expected figure after closing.
const blind = (summary, user) => (user.role === 'admin' || summary.status === 'closed' ? summary : { ...summary, expected_cash: null });

route('GET', '/api/shifts/current', 'user', ({ user }) => {
  const shift = openShift();
  return { shift: shift ? blind(shiftSummary(shift.id), user) : null };
});

route('POST', '/api/shifts', 'user', ({ body, user }) => {
  const float = int(body.opening_float ?? 0, 'Opening float', { min: 0, max: MAX_MONEY });
  try {
    return tx(() => {
      if (openShift()) throw new HttpError(409, 'The till is already open');
      const id = db.prepare("INSERT INTO shifts (opened_by, opened_at, opening_float) VALUES (?, ?, ?)").run(user.id, now(), float).lastInsertRowid;
      audit(user.id, 'till_opened', { shift_id: id, opening_float: float });
      return blind(shiftSummary(id), user);
    });
  } catch (err) { uniqueError(err, 'The till is already open'); }
});

route('POST', '/api/shifts/current/movements', 'user', ({ body, user }) => {
  const type = body.type;
  if (!['paid_in', 'paid_out'].includes(type)) throw bad('Type must be paid_in or paid_out');
  const amount = int(body.amount, 'Amount', { min: 1, max: MAX_MONEY });
  const reason = str(body.reason, 'Reason', { max: 200 });
  return tx(() => {
    const shift = requireShift();
    db.prepare('INSERT INTO cash_movements (shift_id, user_id, type, amount, reason, created_at) VALUES (?, ?, ?, ?, ?, ?)')
      .run(shift.id, user.id, type, amount, reason, now());
    audit(user.id, type === 'paid_in' ? 'cash_paid_in' : 'cash_paid_out', { shift_id: shift.id, amount, reason });
    return blind(shiftSummary(shift.id), user);
  });
});

route('POST', '/api/shifts/current/close', 'user', ({ body, user }) => {
  const counted = int(body.counted_cash, 'Counted cash', { min: 0, max: MAX_MONEY });
  const notes = str(body.notes, 'Notes', { max: 500, required: false });
  return tx(() => {
    const shift = requireShift();
    if (db.prepare("SELECT 1 FROM card_payments WHERE shift_id = ? AND status IN ('starting', 'waiting', 'declined')").get(shift.id)) {
      throw new HttpError(409, 'A card payment is still in progress. Finish or cancel it before closing the till.');
    }
    const expected = shiftSummary(shift.id).expected_cash;
    db.prepare("UPDATE shifts SET status = 'closed', closed_by = ?, closed_at = ?, expected_cash = ?, counted_cash = ?, notes = ? WHERE id = ?")
      .run(user.id, now(), expected, counted, notes || null, shift.id);
    audit(user.id, 'till_closed', { shift_id: shift.id, expected, counted, variance: counted - expected });
    return shiftSummary(shift.id);
  });
});

route('GET', '/api/shifts', 'admin', ({ query }) =>
  db.prepare(`SELECT id FROM shifts WHERE opened_at >= $from AND opened_at < $to ORDER BY id DESC LIMIT 500`)
    .all(dateRange(query)).map((r) => shiftSummary(r.id)));

route('GET', '/api/shifts/:id', 'admin', ({ params }) => shiftSummary(int(params.id, 'id')));

// ---------- sales
function getSale(id) {
  const sale = db.prepare(`SELECT s.*, u.name AS cashier FROM sales s JOIN users u ON u.id = s.user_id WHERE s.id = ?`).get(id);
  if (!sale) throw new HttpError(404, 'Sale not found');
  sale.items = db.prepare('SELECT * FROM sale_items WHERE sale_id = ? ORDER BY id').all(id);
  sale.refunds = db.prepare(`SELECT r.*, u.name AS user_name FROM refunds r LEFT JOIN users u ON u.id = r.user_id
    WHERE r.sale_id = ? ORDER BY r.id`).all(id);
  const refundItems = db.prepare(`SELECT ri.*, i.name, i.sku FROM refund_items ri JOIN sale_items i ON i.id = ri.sale_item_id
    WHERE ri.refund_id = ? ORDER BY ri.id`);
  for (const r of sale.refunds) r.items = refundItems.all(r.id);
  return sale;
}

// Validates and prices a cart. Returns a snapshot that is stored as-is, so the amount
// charged on a card reader is exactly the amount recorded when the sale completes.
function priceCart(body, user) {
  if (!Array.isArray(body.items) || body.items.length === 0) throw bad('The cart is empty');
  if (body.items.length > 500) throw bad('Too many lines in one sale');
  const merged = new Map();
  for (const item of body.items) {
    const productId = int(item?.product_id, 'Product');
    const qty = int(item?.qty, 'Quantity', { min: 1, max: 10_000 });
    merged.set(productId, (merged.get(productId) || 0) + qty);
  }
  const settings = getSettings();
  const discountPct = num(body.discount_pct ?? 0, 'Discount', { min: 0, max: 100 });
  if (user.role !== 'admin' && discountPct > Number(settings.max_cashier_discount)) {
    throw new HttpError(403, `Discounts above ${settings.max_cashier_discount}% need a manager`);
  }
  const taxInclusive = settings.tax_inclusive === '1';
  const allowNegative = settings.allow_negative_stock === '1';
  const lines = [...merged].map(([productId, qty]) => {
    const p = db.prepare('SELECT * FROM products WHERE id = ?').get(productId);
    if (!p || !p.active) throw bad('A product in the cart is no longer available');
    if (p.track_stock && !allowNegative && p.stock < qty) throw bad(`Not enough stock for ${p.name} (${p.stock} left)`);
    return { product: p, qty, unitPrice: p.price, taxRate: p.tax_rate };
  });
  const priced = priceLines(lines, { discountPct, taxInclusive });
  return {
    discount_pct: discountPct,
    tax_inclusive: taxInclusive ? 1 : 0,
    subtotal: priced.subtotal,
    discount: priced.discount,
    tax: priced.tax,
    total: priced.total,
    lines: priced.lines.map((l) => ({
      product_id: l.product.id, sku: l.product.sku, name: l.product.name, unit_price: l.product.price,
      unit_cost: l.product.cost, qty: l.qty, discount: l.discount, tax_rate: l.product.tax_rate,
      tax: l.tax, total: l.total, track_stock: l.product.track_stock,
    })),
  };
}

// Must run inside tx().
function recordSale(snap, { userId, shiftId, method, tendered, card = {}, paymentIntent = null }) {
  const t = now();
  const saleId = db.prepare(`INSERT INTO sales (user_id, shift_id, created_at, subtotal, discount_pct, discount, tax, total, tax_inclusive,
      payment_method, tendered, change_due, stripe_payment_intent, card_brand, card_last4, card_read_method, card_app_name, card_aid, card_auth_code)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(userId, shiftId, t, snap.subtotal, snap.discount_pct, snap.discount, snap.tax, snap.total, snap.tax_inclusive,
      method, tendered, tendered - snap.total, paymentIntent, card.brand ?? null, card.last4 ?? null, card.readMethod ?? null,
      card.appName ?? null, card.aid ?? null, card.authCode ?? null)
    .lastInsertRowid;
  const addItem = db.prepare(`INSERT INTO sale_items (sale_id, product_id, sku, name, unit_price, unit_cost, qty, discount, tax_rate, tax, total)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
  const takeStock = db.prepare('UPDATE products SET stock = stock - ? WHERE id = ?');
  const move = db.prepare("INSERT INTO stock_movements (product_id, change, reason, sale_id, user_id, created_at) VALUES (?, ?, 'sale', ?, ?, ?)");
  for (const l of snap.lines) {
    addItem.run(saleId, l.product_id, l.sku, l.name, l.unit_price, l.unit_cost, l.qty, l.discount, l.tax_rate, l.tax, l.total);
    if (l.track_stock) {
      takeStock.run(l.qty, l.product_id);
      move.run(l.product_id, -l.qty, saleId, userId, t);
    }
  }
  if (snap.discount_pct > 0) audit(userId, 'discount_applied', { sale_id: saleId, discount_pct: snap.discount_pct, amount: snap.discount });
  return saleId;
}

route('POST', '/api/sales', 'user', ({ body, user }) => {
  const method = body.payment_method;
  if (method === 'card' && getSettings().card_mode === 'stripe') throw bad('Card payments go through the card terminal');
  if (!['cash', 'card'].includes(method)) throw bad('Payment method must be cash or card');
  return tx(() => {
    const shift = requireShift();
    const snap = priceCart(body, user);
    let tendered = snap.total;
    if (method === 'cash') {
      tendered = int(body.tendered, 'Amount tendered', { min: 0, max: MAX_MONEY });
      if (tendered < snap.total) throw bad('Amount tendered is less than the total');
    }
    return getSale(recordSale(snap, { userId: user.id, shiftId: shift.id, method, tendered }));
  });
});

route('GET', '/api/sales', 'user', ({ query }) => {
  const limit = Math.min(int(query.get('limit') || 500, 'limit', { min: 1 }), 2000);
  return db.prepare(`SELECT s.id, s.created_at, s.total, s.refunded_amount, s.payment_method, s.card_brand, s.card_last4, s.status,
      u.name AS cashier, (SELECT SUM(qty) FROM sale_items i WHERE i.sale_id = s.id) AS item_count
    FROM sales s JOIN users u ON u.id = s.user_id
    WHERE s.created_at >= $from AND s.created_at < $to ORDER BY s.id DESC LIMIT $limit`)
    .all({ ...dateRange(query), $limit: limit });
});

route('GET', '/api/sales/:id', 'user', ({ params }) => getSale(int(params.id, 'id')));

// ---------- refunds (full or partial, cash, manual card, or back to the card via Stripe)
const refundLocks = new Set();

route('POST', '/api/sales/:id/refunds', 'admin', async ({ params, body, user }) => {
  const saleId = int(params.id, 'id');
  if (refundLocks.has(saleId)) throw new HttpError(409, 'A refund for this sale is already in progress');
  refundLocks.add(saleId);
  try {
    const sale = getSale(saleId);
    const reason = str(body.reason, 'Refund reason', { max: 200 });
    const method = body.method;
    if (!['cash', 'card', 'stripe'].includes(method)) throw bad('Refund method must be cash, card or stripe');
    if (method === 'stripe' && !sale.stripe_payment_intent) throw bad('This sale was not paid on the card terminal');
    if (method === 'card' && (sale.payment_method !== 'card' || sale.stripe_payment_intent)) {
      throw bad('A manual card refund is only for card sales taken outside the card terminal');
    }
    if (!Array.isArray(body.items) || !body.items.length) throw bad('Choose at least one item to refund');
    const restock = body.restock === undefined ? 1 : bool(body.restock);

    const wanted = new Map();
    for (const it of body.items) {
      const id = int(it?.sale_item_id, 'Sale item');
      wanted.set(id, (wanted.get(id) || 0) + int(it?.qty, 'Quantity', { min: 1, max: 10_000 }));
    }
    const lines = [...wanted].map(([id, qty]) => {
      const item = sale.items.find((i) => i.id === id);
      if (!item) throw bad('An item is not part of this sale');
      const remaining = item.qty - item.refunded_qty;
      if (qty > remaining) throw bad(`Only ${remaining} of ${item.name} can be refunded`);
      // The last unit takes whatever is left so partial refunds never add up to more than was paid.
      const last = qty === remaining;
      return {
        item, qty,
        amount: last ? item.total - item.refunded_amount : Math.round((item.total * qty) / item.qty),
        tax: last ? item.tax - item.refunded_tax : Math.round((item.tax * qty) / item.qty),
      };
    });
    const amount = lines.reduce((a, l) => a + l.amount, 0);
    const tax = lines.reduce((a, l) => a + l.tax, 0);
    if (method === 'stripe' && amount <= 0) throw bad('Nothing to refund to the card');
    const shift = method === 'cash' ? requireShift() : openShift();

    let providerRef = null;
    let providerStatus = null;
    if (method === 'stripe') {
      const r = await stripe.createRefund(
        { paymentIntent: sale.stripe_payment_intent, amount, metadata: { pos_sale_id: String(sale.id), reason } },
        `pos-refund-${sale.id}-${randomUUID()}`,
      );
      if (r.status === 'failed' || r.status === 'canceled') throw new HttpError(502, `Card refund ${r.status}: ${r.failure_reason || 'no reason given'}`);
      providerRef = r.id;
      providerStatus = r.status;
    }

    try {
      return tx(() => {
        const t = now();
        const refundId = db.prepare(`INSERT INTO refunds (sale_id, user_id, shift_id, created_at, reason, method, amount, tax, restocked, provider_ref, provider_status)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
          .run(sale.id, user.id, shift?.id ?? null, t, reason, method, amount, tax, restock, providerRef, providerStatus).lastInsertRowid;
        for (const l of lines) {
          db.prepare('INSERT INTO refund_items (refund_id, sale_item_id, qty, amount, tax) VALUES (?, ?, ?, ?, ?)')
            .run(refundId, l.item.id, l.qty, l.amount, l.tax);
          db.prepare('UPDATE sale_items SET refunded_qty = refunded_qty + ?, refunded_amount = refunded_amount + ?, refunded_tax = refunded_tax + ? WHERE id = ?')
            .run(l.qty, l.amount, l.tax, l.item.id);
          const p = restock && l.item.product_id && db.prepare('SELECT id, track_stock FROM products WHERE id = ?').get(l.item.product_id);
          if (p && p.track_stock) {
            db.prepare('UPDATE products SET stock = stock + ? WHERE id = ?').run(l.qty, p.id);
            db.prepare("INSERT INTO stock_movements (product_id, change, reason, sale_id, user_id, created_at) VALUES (?, ?, 'refund', ?, ?, ?)")
              .run(p.id, l.qty, sale.id, user.id, t);
          }
        }
        const left = db.prepare('SELECT SUM(qty - refunded_qty) AS n FROM sale_items WHERE sale_id = ?').get(sale.id).n;
        db.prepare('UPDATE sales SET refunded_amount = refunded_amount + ?, status = ? WHERE id = ?')
          .run(amount, left > 0 ? 'partially_refunded' : 'refunded', sale.id);
        audit(user.id, 'sale_refunded', {
          sale_id: sale.id, refund_id: refundId, amount, method, reason, restocked: !!restock, provider_ref: providerRef,
          items: lines.map((l) => ({ sku: l.item.sku, qty: l.qty })),
        });
        return getSale(sale.id);
      });
    } catch (err) {
      if (providerRef) logError(`CRITICAL: Stripe refund ${providerRef} for sale ${sale.id} went through but was not recorded`, err);
      throw err;
    }
  } finally {
    refundLocks.delete(saleId);
  }
});

// ---------- card terminal (Stripe Terminal, server-driven)
const ACTIVE_CARD = "('starting', 'waiting', 'declined')";
const getCardPayment = (id) => db.prepare('SELECT * FROM card_payments WHERE id = ?').get(id);
const setCardStatus = (id, status, message = null) =>
  db.prepare('UPDATE card_payments SET status = ?, message = ?, updated_at = ? WHERE id = ?').run(status, message, now(), id);
const cardView = (cp) => ({
  id: cp.id, status: cp.status, message: cp.message, amount: cp.amount, reader_id: cp.reader_id,
  created_at: cp.created_at, sale: cp.sale_id ? getSale(cp.sale_id) : null,
});
const publicReader = (r) => ({ id: r.id, label: r.label, device_type: r.device_type, status: r.status, serial_number: r.serial_number, location: r.location });

function terminalSettings() {
  const s = getSettings();
  if (s.card_mode !== 'stripe') throw bad('Card terminal payments are switched off in Settings');
  if (!stripe.stripeConfigured()) throw new HttpError(503, 'Stripe is not set up. Set STRIPE_SECRET_KEY and restart the server.');
  return s;
}

function ownCardPayment(id, user) {
  const cp = getCardPayment(int(id, 'id'));
  if (!cp || (cp.user_id !== user.id && user.role !== 'admin')) throw new HttpError(404, 'Card payment not found');
  return cp;
}

function finaliseCardPayment(id, paymentIntent) {
  return tx(() => {
    const cp = getCardPayment(id);
    if (cp.status === 'succeeded') return cp;
    const snap = JSON.parse(cp.cart);
    const saleId = recordSale(snap, {
      userId: cp.user_id, shiftId: cp.shift_id, method: 'card', tendered: snap.total,
      card: stripe.cardDetails(paymentIntent), paymentIntent: paymentIntent.id,
    });
    db.prepare("UPDATE card_payments SET status = 'succeeded', sale_id = ?, message = NULL, updated_at = ? WHERE id = ?").run(saleId, now(), id);
    return getCardPayment(id);
  });
}

// Asks Stripe where a payment has got to and records the sale once it succeeds.
// Calls for the same payment share one request so a sale can never be recorded twice.
const syncing = new Map();
function syncCardPayment(id) {
  if (!syncing.has(id)) syncing.set(id, doSync(id).finally(() => syncing.delete(id)));
  return syncing.get(id);
}

async function doSync(id) {
  const cp = getCardPayment(id);
  if (!cp?.payment_intent || !['starting', 'waiting', 'declined'].includes(cp.status)) return cp;
  let pi = await stripe.getPaymentIntent(cp.payment_intent);
  if (pi.status === 'requires_capture') {
    await stripe.capturePaymentIntent(pi.id);
    pi = await stripe.getPaymentIntent(pi.id);
  }
  if (pi.status === 'succeeded') return finaliseCardPayment(cp.id, pi);
  if (pi.status === 'canceled') {
    setCardStatus(cp.id, 'canceled', 'Payment was cancelled');
  } else if (cp.status === 'waiting' && pi.status === 'requires_payment_method') {
    const reader = await stripe.getReader(cp.reader_id);
    const action = reader.action;
    const actionPi = action?.process_payment_intent?.payment_intent;
    const ours = (typeof actionPi === 'object' ? actionPi?.id : actionPi) === pi.id;
    if (ours && action.status === 'failed') {
      setCardStatus(cp.id, 'declined', action.failure_message || pi.last_payment_error?.message || 'Card declined');
    } else if (!ours) {
      setCardStatus(cp.id, 'declined', pi.last_payment_error?.message || 'The reader stopped waiting for this payment');
    }
  }
  return getCardPayment(cp.id);
}

route('GET', '/api/terminal/status', 'user', async () => {
  const s = getSettings();
  const out = {
    mode: s.card_mode, configured: stripe.stripeConfigured(), testMode: stripe.stripeTestMode(),
    defaultReader: s.stripe_reader_id, readers: [],
  };
  if (s.card_mode === 'stripe' && out.configured) {
    try { out.readers = (await stripe.listReaders()).map(publicReader); } catch (err) { out.error = err.message; }
  }
  return out;
});

route('POST', '/api/terminal/payments', 'user', async ({ body, user }) => {
  const settings = terminalSettings();
  const readerId = str(body.reader_id || settings.stripe_reader_id, 'Card reader', { max: 100 });
  if (!/^tmr_\w+$/.test(readerId)) throw bad('Choose a card reader');
  const cp = tx(() => {
    const shift = requireShift();
    if (db.prepare(`SELECT 1 FROM card_payments WHERE reader_id = ? AND status IN ${ACTIVE_CARD}`).get(readerId)) {
      throw new HttpError(409, 'That reader is busy with another payment. Finish or cancel it first.');
    }
    const snap = priceCart(body, user);
    if (snap.total <= 0) throw bad('A card payment must be more than zero');
    const t = now();
    const id = db.prepare(`INSERT INTO card_payments (user_id, shift_id, reader_id, amount, currency, cart, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 'starting', ?, ?)`)
      .run(user.id, shift.id, readerId, snap.total, settings.currency, JSON.stringify(snap), t, t).lastInsertRowid;
    return getCardPayment(id);
  });
  try {
    const pi = await stripe.createPaymentIntent({
      amount: cp.amount,
      currency: cp.currency,
      description: `${settings.store_name} POS payment ${cp.id}`,
      metadata: { pos_card_payment_id: String(cp.id), pos_user: user.username },
    }, `pos-cp-${cp.id}-${cp.created_at}`);
    db.prepare('UPDATE card_payments SET payment_intent = ?, updated_at = ? WHERE id = ?').run(pi.id, now(), cp.id);
    await stripe.processOnReader(readerId, pi.id);
    setCardStatus(cp.id, 'waiting');
  } catch (err) {
    const fresh = getCardPayment(cp.id);
    if (fresh.payment_intent) await stripe.cancelPaymentIntent(fresh.payment_intent).catch(() => {});
    setCardStatus(cp.id, 'error', err.message);
    throw err;
  }
  return cardView(getCardPayment(cp.id));
});

route('GET', '/api/terminal/payments/active', 'user', ({ user }) =>
  db.prepare(`SELECT * FROM card_payments WHERE user_id = ? AND status IN ${ACTIVE_CARD} ORDER BY id`).all(user.id).map(cardView));

route('GET', '/api/terminal/payments/:id', 'user', async ({ params, user }) => {
  const cp = ownCardPayment(params.id, user);
  return cardView(await syncCardPayment(cp.id));
});

route('POST', '/api/terminal/payments/:id/retry', 'user', async ({ params, user }) => {
  const cp = ownCardPayment(params.id, user);
  if (cp.status !== 'declined') throw bad('Only a declined payment can be retried');
  await stripe.processOnReader(cp.reader_id, cp.payment_intent);
  setCardStatus(cp.id, 'waiting');
  return cardView(getCardPayment(cp.id));
});

route('POST', '/api/terminal/payments/:id/cancel', 'user', async ({ params, user }) => {
  const cp = ownCardPayment(params.id, user);
  if (!['starting', 'waiting', 'declined'].includes(cp.status)) return cardView(cp);
  await stripe.cancelReaderAction(cp.reader_id).catch(() => {});
  try {
    if (cp.payment_intent) await stripe.cancelPaymentIntent(cp.payment_intent);
  } catch (err) {
    // The customer may have paid just before the cancel arrived.
    const synced = await syncCardPayment(cp.id);
    if (synced.status === 'succeeded') return cardView(synced);
    throw err;
  }
  setCardStatus(cp.id, 'canceled', 'Cancelled by cashier');
  audit(user.id, 'card_payment_cancelled', { card_payment_id: cp.id, amount: cp.amount });
  return cardView(getCardPayment(cp.id));
});

route('POST', '/api/terminal/payments/:id/simulate', 'user', async ({ params, body, user }) => {
  if (!stripe.stripeTestMode()) throw new HttpError(403, 'Simulated cards only work with a Stripe test key');
  const cp = ownCardPayment(params.id, user);
  if (cp.status !== 'waiting') throw bad('The reader is not waiting for a card');
  await stripe.simulateCardTap(cp.reader_id, bool(body.decline));
  return cardView(await syncCardPayment(cp.id));
});

// Terminal set-up (managers)
route('GET', '/api/terminal/setup', 'admin', async () => {
  const out = { configured: stripe.stripeConfigured(), testMode: stripe.stripeTestMode(), locations: [], readers: [] };
  if (out.configured) {
    [out.locations, out.readers] = await Promise.all([stripe.listLocations(), stripe.listReaders().then((r) => r.map(publicReader))]);
    out.locations = out.locations.map((l) => ({ id: l.id, display_name: l.display_name, address: l.address }));
  }
  return out;
});

route('POST', '/api/terminal/locations', 'admin', async ({ body, user }) => {
  const location = await stripe.createLocation(str(body.display_name, 'Location name', { max: 100 }), {
    line1: str(body.line1, 'Address line 1', { max: 200 }),
    city: str(body.city, 'Town or city', { max: 100 }),
    postal_code: str(body.postal_code, 'Postcode', { max: 20 }),
    country: str(body.country, 'Country', { max: 2 }).toUpperCase(),
  });
  audit(user.id, 'terminal_location_created', { id: location.id, name: location.display_name });
  return { id: location.id, display_name: location.display_name };
});

route('POST', '/api/terminal/readers', 'admin', async ({ body, user }) => {
  const reader = await stripe.registerReader(
    str(body.registration_code, 'Registration code', { max: 100 }),
    str(body.label, 'Reader name', { max: 100 }),
    str(body.location, 'Location', { max: 100 }),
  );
  audit(user.id, 'terminal_reader_registered', { id: reader.id, label: reader.label, serial: reader.serial_number });
  return publicReader(reader);
});

route('DELETE', '/api/terminal/readers/:id', 'admin', async ({ params, user }) => {
  await stripe.deleteReader(params.id);
  audit(user.id, 'terminal_reader_removed', { id: params.id });
});

// Background check: records card sales even if the till browser was closed mid-payment,
// and cancels payments left waiting for too long.
const STALE_MS = 15 * 60 * 1000;
let reconciling = false;
setInterval(async () => {
  if (reconciling || !stripe.stripeConfigured()) return;
  reconciling = true;
  try {
    for (const { id } of db.prepare(`SELECT id FROM card_payments WHERE status IN ${ACTIVE_CARD}`).all()) {
      try {
        let cp = await syncCardPayment(id);
        if (cp.status === 'succeeded' || Date.now() - Date.parse(cp.created_at) < STALE_MS) continue;
        if (cp.payment_intent) {
          await stripe.cancelReaderAction(cp.reader_id).catch(() => {});
          await stripe.cancelPaymentIntent(cp.payment_intent).catch(() => {});
          cp = await syncCardPayment(id);
        }
        if (cp.status !== 'succeeded') setCardStatus(id, cp.payment_intent ? 'canceled' : 'error', 'Timed out');
      } catch (err) {
        logError(`Card payment ${id} check failed`, err);
      }
    }
  } finally {
    reconciling = false;
  }
}, 20_000).unref();

// ---------- reports
route('GET', '/api/reports/summary', 'admin', ({ query }) => {
  const r = dateRange(query);
  const sales = db.prepare(`SELECT COUNT(*) AS count, COALESCE(SUM(total), 0) AS total, COALESCE(SUM(tax), 0) AS tax,
    COALESCE(SUM(discount), 0) AS discount FROM sales WHERE created_at >= $from AND created_at < $to`).get(r);
  const refunds = db.prepare(`SELECT COUNT(*) AS count, COALESCE(SUM(amount), 0) AS total, COALESCE(SUM(tax), 0) AS tax
    FROM refunds WHERE created_at >= $from AND created_at < $to`).get(r);
  const methods = {};
  for (const m of ['cash', 'card']) methods[m] = { method: m, sales: 0, refunds: 0, net: 0 };
  for (const row of db.prepare(`SELECT payment_method AS m, SUM(total) AS t FROM sales
      WHERE created_at >= $from AND created_at < $to GROUP BY payment_method`).all(r)) methods[row.m].sales = row.t;
  for (const row of db.prepare(`SELECT CASE method WHEN 'cash' THEN 'cash' ELSE 'card' END AS m, SUM(amount) AS t FROM refunds
      WHERE created_at >= $from AND created_at < $to GROUP BY 1`).all(r)) methods[row.m].refunds = row.t;
  for (const m of Object.values(methods)) m.net = m.sales - m.refunds;
  const margin = db.prepare(`SELECT COALESCE(SUM(i.total - i.tax - i.refunded_amount + i.refunded_tax), 0) AS revenue,
      COALESCE(SUM(i.unit_cost * (i.qty - i.refunded_qty)), 0) AS cost
    FROM sale_items i JOIN sales s ON s.id = i.sale_id WHERE s.created_at >= $from AND s.created_at < $to`).get(r);
  const topProducts = db.prepare(`SELECT i.sku, i.name, SUM(i.qty - i.refunded_qty) AS qty, SUM(i.total - i.refunded_amount) AS total
    FROM sale_items i JOIN sales s ON s.id = i.sale_id WHERE s.created_at >= $from AND s.created_at < $to
    GROUP BY i.sku, i.name HAVING qty > 0 ORDER BY total DESC LIMIT 10`).all(r);
  const byCashier = db.prepare(`SELECT u.name, COUNT(*) AS count, SUM(s.total - s.refunded_amount) AS total FROM sales s
    JOIN users u ON u.id = s.user_id WHERE s.created_at >= $from AND s.created_at < $to GROUP BY u.id ORDER BY total DESC`).all(r);
  const lowStock = db.prepare(`SELECT id, sku, name, stock, low_stock FROM products
    WHERE active = 1 AND track_stock = 1 AND stock <= low_stock ORDER BY stock, name`).all();
  return {
    sales, refunds,
    net: { total: sales.total - refunds.total, tax: sales.tax - refunds.tax },
    margin: { ...margin, profit: margin.revenue - margin.cost },
    methods: Object.values(methods), topProducts, byCashier, lowStock,
  };
});

function csvCell(v) {
  let s = String(v ?? '');
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`; // block spreadsheet formula injection
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

route('GET', '/api/reports/sales.csv', 'admin', ({ query, user }) => {
  const settings = getSettings();
  const f = 10 ** minorDigits(settings);
  const money = (m) => (m / f).toFixed(Math.log10(f));
  const rows = db.prepare(`SELECT s.*, u.name AS cashier, (SELECT SUM(qty) FROM sale_items i WHERE i.sale_id = s.id) AS items
    FROM sales s JOIN users u ON u.id = s.user_id WHERE s.created_at >= $from AND s.created_at < $to ORDER BY s.id`).all(dateRange(query));
  const header = ['Receipt', 'Date (UTC)', 'Cashier', 'Till session', 'Items', 'Subtotal', 'Discount', settings.tax_label, 'Total',
    'Refunded', 'Payment', 'Card', 'Stripe payment', 'Status'];
  const lines = [header, ...rows.map((s) => [
    String(s.id).padStart(6, '0'), s.created_at, s.cashier, s.shift_id, s.items, money(s.subtotal), money(s.discount), money(s.tax),
    money(s.total), money(s.refunded_amount), s.payment_method, s.card_last4 ? `${s.card_brand} ${s.card_last4}` : '',
    s.stripe_payment_intent, s.status,
  ])].map((r) => r.map(csvCell).join(','));
  audit(user.id, 'sales_exported', { rows: rows.length });
  return new Raw(`﻿${lines.join('\r\n')}\r\n`, { 'Content-Type': 'text/csv; charset=utf-8' });
});

// ---------- users
const PIN_RE = /^\d{4,8}$/;

route('GET', '/api/users', 'admin', () =>
  db.prepare('SELECT id, username, name, role, active, created_at FROM users ORDER BY active DESC, name').all());

route('POST', '/api/users', 'admin', ({ body, user }) => {
  const username = str(body.username, 'Username', { max: 50 }).toLowerCase();
  if (!/^[a-z0-9._-]+$/.test(username)) throw bad('Username may only contain letters, numbers, dots, dashes and underscores');
  const name = str(body.name, 'Name', { max: 100 });
  const role = body.role === 'admin' ? 'admin' : 'cashier';
  const pin = str(body.pin, 'PIN', { max: 12 });
  if (!PIN_RE.test(pin)) throw bad('PIN must be 4 to 8 digits');
  try {
    const id = db.prepare('INSERT INTO users (username, name, pin_hash, role, created_at) VALUES (?, ?, ?, ?, ?)')
      .run(username, name, hashPin(pin), role, now()).lastInsertRowid;
    audit(user.id, 'user_created', { id, username, role });
    return { id, username, name, role, active: 1 };
  } catch (err) { uniqueError(err, 'That username is already taken'); }
});

route('PUT', '/api/users/:id', 'admin', ({ params, body, user }) => {
  const target = db.prepare('SELECT * FROM users WHERE id = ?').get(int(params.id, 'id'));
  if (!target) throw new HttpError(404, 'User not found');
  const name = str(body.name ?? target.name, 'Name', { max: 100 });
  const role = body.role === undefined ? target.role : body.role === 'admin' ? 'admin' : 'cashier';
  const active = body.active === undefined ? target.active : bool(body.active);
  const pin = str(body.pin, 'PIN', { max: 12, required: false });
  if (pin && !PIN_RE.test(pin)) throw bad('PIN must be 4 to 8 digits');
  if (target.role === 'admin' && target.active && (role !== 'admin' || !active)) {
    const others = db.prepare("SELECT COUNT(*) AS n FROM users WHERE role = 'admin' AND active = 1 AND id != ?").get(target.id).n;
    if (!others) throw bad('At least one active manager account is required');
  }
  tx(() => {
    db.prepare('UPDATE users SET name = ?, role = ?, active = ? WHERE id = ?').run(name, role, active, target.id);
    if (pin) db.prepare('UPDATE users SET pin_hash = ? WHERE id = ?').run(hashPin(pin), target.id);
    audit(user.id, 'user_updated', {
      id: target.id, username: target.username,
      ...(role !== target.role && { role: { from: target.role, to: role } }),
      ...(active !== target.active && { active: { from: target.active, to: active } }),
      ...(pin && { pin: 'reset' }),
    });
  });
  if (!active || pin || role !== target.role) endSessionsFor(target.id, user.token);
  return db.prepare('SELECT id, username, name, role, active, created_at FROM users WHERE id = ?').get(target.id);
});

// ---------- system panel (managers)
const MB = 1024 * 1024;
const fileSize = (f) => (existsSync(f) ? statSync(f).size : 0);

route('GET', '/api/system/health', 'admin', async () => {
  const count = (table) => db.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get().n;
  const backups = listBackups();
  let disk = null;
  try {
    const fsStats = statfsSync(DATA_DIR);
    disk = { free: fsStats.bavail * fsStats.bsize, total: fsStats.blocks * fsStats.bsize };
  } catch { /* not available on this platform */ }

  const settings = getSettings();
  const stripeInfo = { configured: stripe.stripeConfigured(), testMode: stripe.stripeTestMode(), mode: settings.card_mode };
  if (stripeInfo.configured) {
    const started = Date.now();
    try {
      stripeInfo.readers = (await stripe.listReaders()).map(publicReader);
      stripeInfo.latency_ms = Date.now() - started;
    } catch (err) {
      stripeInfo.error = err.message;
    }
  }

  const stuck = db.prepare(`SELECT c.id, c.status, c.message, c.amount, c.reader_id, c.created_at, u.name AS user_name
    FROM card_payments c JOIN users u ON u.id = c.user_id WHERE c.status IN ${ACTIVE_CARD} AND c.created_at < ? ORDER BY c.id`)
    .all(new Date(Date.now() - 2 * 60_000).toISOString());

  const warnings = [];
  const weakPin = db.prepare('SELECT username, pin_hash FROM users WHERE active = 1').all().filter((u) => verifyPin('1234', u.pin_hash));
  if (weakPin.length) warnings.push(`These accounts still use PIN 1234: ${weakPin.map((u) => u.username).join(', ')}. Change them now.`);
  if (/onedrive|dropbox|google drive|icloud/i.test(DATA_DIR)) {
    warnings.push('The database is in a cloud-synced folder. Sync can corrupt a database in use. Set POS_DATA_DIR to a local folder.');
  }
  const lastBackup = backups[0];
  if (!lastBackup) warnings.push('There are no backups yet.');
  else if (Date.now() - Date.parse(lastBackup.created_at) > 2 * 86_400_000) warnings.push('The newest backup is more than 2 days old.');
  if (disk && disk.free < 500 * MB) warnings.push('Less than 500 MB of disk space is left.');
  if (settings.card_mode === 'stripe' && !stripeInfo.configured) warnings.push('Card payments are set to Stripe Terminal, but no Stripe key is set.');
  if (stuck.length) warnings.push(`${stuck.length} card payment(s) have been in progress for more than 2 minutes.`);
  if (stripeInfo.readers?.some((r) => r.status !== 'online')) warnings.push('One or more card readers are offline.');

  return {
    warnings,
    server: {
      started_at: STARTED_AT.toISOString(), uptime_s: Math.round(process.uptime()), node: process.version,
      platform: `${os.type()} ${os.release()}`, host: os.hostname(), memory_mb: Math.round(process.memoryUsage().rss / MB),
      listening: `${HOST}:${PORT}`,
    },
    database: {
      path: DB_PATH, size: fileSize(DB_PATH) + fileSize(`${DB_PATH}-wal`),
      schema_version: db.prepare('PRAGMA user_version').get().user_version,
      counts: Object.fromEntries(['products', 'sales', 'refunds', 'shifts', 'users', 'stock_movements', 'audit_log'].map((t) => [t, count(t)])),
    },
    disk,
    backups: { count: backups.length, last: lastBackup || null },
    stripe: stripeInfo,
    stuck_card_payments: stuck,
    sessions: sessions.size,
    errors: recentErrors,
  };
});

// Backups
route('GET', '/api/system/backups', 'admin', () => ({ dir: BACKUP_DIR, keep_auto: AUTO_KEEP, backups: listBackups() }));

route('POST', '/api/system/backups', 'admin', ({ user }) => {
  const b = createBackup(false);
  audit(user.id, 'backup_created', { name: b.name, size: b.size });
  return b;
});

route('GET', '/api/system/backups/:name', 'admin', ({ params, user }) => {
  const file = backupFile(params.name);
  if (!file) throw new HttpError(404, 'Backup not found');
  audit(user.id, 'backup_downloaded', params.name);
  return new Raw(readFileSync(file), {
    'Content-Type': 'application/vnd.sqlite3',
    'Content-Disposition': `attachment; filename="${params.name}"`,
  });
});

route('DELETE', '/api/system/backups/:name', 'admin', ({ params, user }) => {
  if (!deleteBackup(params.name)) throw new HttpError(404, 'Backup not found');
  audit(user.id, 'backup_deleted', params.name);
});

// Sessions and security
route('GET', '/api/system/sessions', 'admin', ({ user }) => {
  const names = new Map(db.prepare('SELECT id, name, username, role FROM users').all().map((u) => [u.id, u]));
  return [...sessions].filter(([, s]) => s.expires > Date.now()).map(([token, s]) => ({
    sid: s.sid, user: names.get(s.userId)?.name, username: names.get(s.userId)?.username, role: names.get(s.userId)?.role,
    created_at: new Date(s.createdAt).toISOString(), last_seen: new Date(s.lastSeen).toISOString(),
    ip: s.ip, agent: s.agent, current: token === user.token,
  })).sort((a, b) => b.last_seen.localeCompare(a.last_seen));
});

route('DELETE', '/api/system/sessions/:sid', 'admin', ({ params, user }) => {
  for (const [token, s] of sessions) {
    if (s.sid !== params.sid) continue;
    if (token === user.token) throw bad('Use "Sign out" to end your own session');
    sessions.delete(token);
    audit(user.id, 'session_ended', { user_id: s.userId, ip: s.ip });
    return;
  }
  throw new HttpError(404, 'Session not found');
});

route('POST', '/api/system/sessions/end-others', 'admin', ({ user }) => {
  let ended = 0;
  for (const token of sessions.keys()) if (token !== user.token) { sessions.delete(token); ended++; }
  audit(user.id, 'sessions_ended', { count: ended });
  return { ended };
});

route('GET', '/api/system/security', 'admin', () => ({
  locks: [...loginFailures].map(([username, f]) => ({
    username, failures: f.count, locked_until: f.until > Date.now() ? new Date(f.until).toISOString() : null,
  })),
  failed_logins: db.prepare(`SELECT created_at, detail AS username FROM audit_log WHERE action = 'login_failed' AND created_at >= ?
    ORDER BY id DESC LIMIT 100`).all(new Date(Date.now() - 7 * 86_400_000).toISOString()),
}));

route('DELETE', '/api/system/locks/:username', 'admin', ({ params, user }) => {
  if (!loginFailures.delete(params.username.toLowerCase())) throw new HttpError(404, 'That account is not locked');
  audit(user.id, 'account_unlocked', params.username);
});

// Data tools
route('GET', '/api/system/export', 'admin', ({ user }) => {
  const tables = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all().map((t) => t.name);
  const files = tables.map((table) => {
    const cols = db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name).filter((c) => c !== 'pin_hash');
    const rows = db.prepare(`SELECT ${cols.map((c) => `"${c}"`).join(', ')} FROM ${table} ORDER BY rowid`).all();
    const csv = [cols, ...rows.map((r) => cols.map((c) => r[c]))].map((r) => r.map(csvCell).join(',')).join('\r\n');
    return { name: `${table}.csv`, data: `﻿${csv}\r\n` };
  });
  const s = getSettings();
  files.unshift({ name: 'README.txt', data: [
    `Full data export from ${s.store_name}, ${now()}.`,
    '',
    'One CSV file per database table. Dates are in UTC (ISO 8601).',
    `Money is in minor units (for example pence): divide by ${10 ** minorDigits(s)} for ${s.currency}.`,
    'Staff PIN hashes are left out on purpose.',
    'To restore the POS, use a backup (.db file), not this export.',
  ].join('\r\n') });
  audit(user.id, 'data_exported', { tables: tables.length });
  const stamp = new Date().toISOString().slice(0, 10);
  return new Raw(zip(files), { 'Content-Type': 'application/zip', 'Content-Disposition': `attachment; filename="pos-export-${stamp}.zip"` });
});

route('POST', '/api/system/integrity', 'admin', ({ user }) => {
  const result = runIntegrityChecks();
  audit(user.id, 'integrity_check', { ok: result.ok, failed: result.checks.filter((c) => !c.ok).map((c) => c.name) });
  return result;
});

function demoProducts() {
  const known = new Map(Object.values(DEMO_CATALOGUE).flat().map(([sku, , name]) => [sku.toLowerCase(), name]));
  return db.prepare('SELECT id, sku, name, active FROM products').all()
    .filter((p) => known.get(p.sku.toLowerCase()) === p.name)
    .map((p) => {
      const sold = !!db.prepare('SELECT 1 FROM sale_items WHERE product_id = ? LIMIT 1').get(p.id);
      return { ...p, has_sales: sold, action: sold ? 'deactivate' : 'delete' };
    });
}

route('GET', '/api/system/demo', 'admin', () => demoProducts());

route('POST', '/api/system/demo/clear', 'admin', ({ user }) => tx(() => {
  const list = demoProducts();
  for (const p of list) {
    if (p.has_sales) {
      db.prepare('UPDATE products SET active = 0, updated_at = ? WHERE id = ?').run(now(), p.id);
    } else {
      db.prepare('DELETE FROM stock_movements WHERE product_id = ?').run(p.id);
      db.prepare('DELETE FROM products WHERE id = ?').run(p.id);
    }
  }
  const cats = Object.keys(DEMO_CATALOGUE);
  const removedCats = db.prepare(`DELETE FROM categories WHERE name IN (${cats.map(() => '?').join(', ')})
    AND id NOT IN (SELECT category_id FROM products WHERE category_id IS NOT NULL)`).run(...cats).changes;
  const summary = {
    deleted: list.filter((p) => !p.has_sales).length,
    deactivated: list.filter((p) => p.has_sales).length,
    categories_deleted: removedCats,
  };
  audit(user.id, 'demo_data_cleared', summary);
  return summary;
}));

// Daily automatic backup, checked every hour (and shortly after start).
function autoBackup() {
  if (process.env.AUTO_BACKUP === '0' || !autoBackupDue()) return;
  try {
    const b = createBackup(true);
    pruneAutoBackups();
    audit(null, 'backup_created', { name: b.name, size: b.size, automatic: true });
  } catch (err) {
    logError('Automatic backup failed', err);
  }
}
setTimeout(autoBackup, 10_000).unref();
setInterval(autoBackup, 3600_000).unref();

// ---------- audit log
route('GET', '/api/audit', 'admin', ({ query }) =>
  db.prepare(`SELECT a.*, u.name AS user_name FROM audit_log a LEFT JOIN users u ON u.id = a.user_id
    WHERE a.created_at >= $from AND a.created_at < $to ORDER BY a.id DESC LIMIT 1000`).all(dateRange(query)));

// ---------- HTTP plumbing
function send(res, status, data, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...SECURITY_HEADERS,
    ...headers,
  });
  res.end(typeof data === 'string' || Buffer.isBuffer(data) ? data : JSON.stringify(data));
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 1_000_000) { reject(new HttpError(413, 'Request too large')); req.destroy(); } else chunks.push(c);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (!body || typeof body !== 'object' || Array.isArray(body)) return reject(bad('Request body must be a JSON object'));
        resolve(body);
      } catch { reject(bad('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

async function handleApi(req, res, url) {
  for (const r of routes) {
    if (r.method !== req.method) continue;
    const m = r.re.exec(url.pathname);
    if (!m) continue;
    const user = authUser(req);
    if (r.role && !user) throw new HttpError(401, 'Please log in');
    if (r.role === 'admin' && user.role !== 'admin') throw new HttpError(403, 'Manager access required');
    const body = req.method === 'POST' || req.method === 'PUT' ? await readJson(req) : {};
    const params = Object.fromEntries(Object.entries(m.groups || {}).map(([k, v]) => [k, decodeURIComponent(v)]));
    const result = await r.handler({ req, body, query: url.searchParams, params, user });
    if (result instanceof Raw) return send(res, 200, result.body, result.headers);
    return send(res, 200, result ?? { ok: true });
  }
  throw new HttpError(404, 'Not found');
}

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.json': 'application/json',
};

async function serveStatic(req, res, pathname) {
  if (req.method !== 'GET' && req.method !== 'HEAD') throw new HttpError(405, 'Method not allowed');
  let rel;
  try { rel = pathname === '/' ? 'index.html' : decodeURIComponent(pathname).replace(/^\/+/, ''); } catch { throw bad('Bad path'); }
  const file = path.resolve(PUBLIC, rel);
  if (!file.startsWith(PUBLIC + path.sep)) throw new HttpError(404, 'Not found');
  let data;
  try { data = await readFile(file); } catch { throw new HttpError(404, 'Not found'); }
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache', ...SECURITY_HEADERS });
  res.end(req.method === 'HEAD' ? undefined : data);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname.startsWith('/api/')) await handleApi(req, res, url);
    else await serveStatic(req, res, url.pathname);
  } catch (err) {
    let status = err.status || 500;
    let message = err.message;
    if (err instanceof stripe.StripeError) {
      status = err.status === 503 ? 503 : 502;
      message = `Card terminal: ${err.message}`;
    }
    if (status === 500) logError(`${req.method} ${url.pathname}`, err);
    if (!res.headersSent) send(res, status, { error: status === 500 ? 'Internal server error' : message });
    else res.end();
  }
});

server.listen(PORT, HOST, () => {
  const mode = stripe.stripeConfigured() ? (stripe.stripeTestMode() ? 'Stripe TEST mode' : 'Stripe LIVE mode') : 'Stripe not configured';
  console.log(`POS running at http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${PORT} (${mode})`);
});
