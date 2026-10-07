// Checks that the database is sound and that the shop's records agree with each other.
import { db } from './db.js';

const MAX_ISSUES = 20;

export function runIntegrityChecks() {
  const checks = [];
  const add = (name, description, issues) =>
    checks.push({ name, description, ok: issues.length === 0, count: issues.length, issues: issues.slice(0, MAX_ISSUES) });

  const structure = db.prepare('PRAGMA integrity_check').all().map((r) => Object.values(r)[0]);
  add('Database file', 'The SQLite file is not damaged.', structure[0] === 'ok' ? [] : structure);

  add('Record links', 'Every record points to records that exist.',
    db.prepare('PRAGMA foreign_key_check').all().map((r) => `${r.table} row ${r.rowid} points to a missing ${r.parent} record`));

  add('Sale totals', 'Each sale total equals the sum of its items.',
    db.prepare(`SELECT s.id, s.total, SUM(i.total) AS items FROM sales s LEFT JOIN sale_items i ON i.sale_id = s.id
      GROUP BY s.id HAVING items IS NULL OR items != s.total`).all()
      .map((r) => `Sale #${r.id}: total ${r.total}, items add up to ${r.items ?? 'nothing'}`));

  add('Cash change', 'Change given equals amount tendered minus total.',
    db.prepare('SELECT id, tendered, total, change_due FROM sales WHERE change_due != tendered - total').all()
      .map((r) => `Sale #${r.id}: tendered ${r.tendered}, total ${r.total}, change recorded ${r.change_due}`));

  add('Refund amounts', 'Refunded amount on each sale equals its refund records.',
    db.prepare(`SELECT s.id, s.refunded_amount, COALESCE((SELECT SUM(amount) FROM refunds r WHERE r.sale_id = s.id), 0) AS refunds
      FROM sales s WHERE refunded_amount != refunds`).all()
      .map((r) => `Sale #${r.id}: shows ${r.refunded_amount} refunded, refund records add up to ${r.refunds}`));

  add('Refund quantities', 'No item is refunded more times than it was sold.',
    db.prepare(`SELECT i.id, i.sale_id, i.name, i.qty, i.refunded_qty,
        COALESCE((SELECT SUM(qty) FROM refund_items ri WHERE ri.sale_item_id = i.id), 0) AS recorded
      FROM sale_items i WHERE refunded_qty > qty OR refunded_qty < 0 OR refunded_qty != recorded`).all()
      .map((r) => `Sale #${r.sale_id} ${r.name}: sold ${r.qty}, refunded ${r.refunded_qty}, refund records ${r.recorded}`));

  add('Sale status', 'Each sale is marked completed, partly refunded or refunded correctly.',
    db.prepare(`SELECT s.id, s.status, SUM(i.qty) AS sold, SUM(i.refunded_qty) AS back FROM sales s
      JOIN sale_items i ON i.sale_id = s.id GROUP BY s.id
      HAVING status != CASE WHEN back = 0 THEN 'completed' WHEN back >= sold THEN 'refunded' ELSE 'partially_refunded' END`).all()
      .map((r) => `Sale #${r.id} is marked ${r.status} but ${r.back} of ${r.sold} items are refunded`));

  add('Stock levels', 'Each product\'s stock equals its stock movement history.',
    db.prepare(`SELECT p.sku, p.name, p.stock, COALESCE(SUM(m.change), 0) AS moved FROM products p
      LEFT JOIN stock_movements m ON m.product_id = p.id GROUP BY p.id HAVING moved != p.stock`).all()
      .map((r) => `${r.sku} ${r.name}: stock ${r.stock}, movement history adds up to ${r.moved}`));

  add('Till sessions', 'Closed till sessions have a count and the variance can be worked out.',
    db.prepare("SELECT id FROM shifts WHERE status = 'closed' AND (counted_cash IS NULL OR expected_cash IS NULL)").all()
      .map((r) => `Till session #${r.id} is closed without a count`));

  return { ran_at: new Date().toISOString(), ok: checks.every((c) => c.ok), checks };
}
