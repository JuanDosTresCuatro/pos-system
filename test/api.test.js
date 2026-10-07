import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startServer } from './helpers.js';

let pos;
before(async () => { pos = await startServer(); });
after(() => pos.stop());

const findProduct = async (token, sku) => (await pos.call('GET', '/api/products', null, token)).data.find((p) => p.sku === sku);

test('rejects unauthenticated and wrong-PIN requests', async () => {
  assert.equal((await pos.call('GET', '/api/products')).status, 401);
  assert.equal((await pos.call('POST', '/api/login', { username: 'admin', pin: '9999' })).status, 401);
});

test('sales need an open till', async () => {
  const admin = await pos.login('admin', '1234');
  const cola = await findProduct(admin, 'DRK-001');
  const r = await pos.call('POST', '/api/sales', { items: [{ product_id: cola.id, qty: 1 }], payment_method: 'cash', tendered: 500 }, admin);
  assert.equal(r.status, 409);
  assert.equal((await pos.call('POST', '/api/shifts', { opening_float: 10000 }, admin)).status, 200);
  assert.equal((await pos.call('POST', '/api/shifts', { opening_float: 0 }, admin)).status, 409);
});

test('sale, partial refund, full refund and stock', async () => {
  const admin = await pos.login('admin', '1234');
  const cola = await findProduct(admin, 'DRK-001');
  const sale = await pos.call('POST', '/api/sales', {
    items: [{ product_id: cola.id, qty: 3 }], payment_method: 'cash', tendered: 500,
  }, admin);
  assert.equal(sale.status, 200);
  assert.equal(sale.data.total, 360);
  assert.equal(sale.data.tax, 60);
  assert.equal(sale.data.change_due, 140);
  assert.equal((await findProduct(admin, 'DRK-001')).stock, cola.stock - 3);

  const item = sale.data.items[0];
  const part = await pos.call('POST', `/api/sales/${sale.data.id}/refunds`, {
    items: [{ sale_item_id: item.id, qty: 1 }], method: 'cash', reason: 'one was dented', restock: true,
  }, admin);
  assert.equal(part.status, 200);
  assert.equal(part.data.status, 'partially_refunded');
  assert.equal(part.data.refunded_amount, 120);
  assert.equal((await findProduct(admin, 'DRK-001')).stock, cola.stock - 2);

  const tooMany = await pos.call('POST', `/api/sales/${sale.data.id}/refunds`, {
    items: [{ sale_item_id: item.id, qty: 3 }], method: 'cash', reason: 'x',
  }, admin);
  assert.equal(tooMany.status, 400);

  const rest = await pos.call('POST', `/api/sales/${sale.data.id}/refunds`, {
    items: [{ sale_item_id: item.id, qty: 2 }], method: 'cash', reason: 'returned', restock: false,
  }, admin);
  assert.equal(rest.data.status, 'refunded');
  assert.equal(rest.data.refunded_amount, 360);
  assert.equal(rest.data.refunds.length, 2);
  assert.equal((await findProduct(admin, 'DRK-001')).stock, cola.stock - 2, 'not restocked when restock is off');

  const wrongMethod = await pos.call('POST', `/api/sales/${sale.data.id}/refunds`, {
    items: [{ sale_item_id: item.id, qty: 1 }], method: 'stripe', reason: 'x',
  }, admin);
  assert.equal(wrongMethod.status, 400);
});

test('partial refunds never add up to more than was paid', async () => {
  const admin = await pos.login('admin', '1234');
  const water = await findProduct(admin, 'DRK-002');
  // 3 x 1.00 with 33% discount = 201 total; split three ways must sum to exactly 201.
  const sale = (await pos.call('POST', '/api/sales', {
    items: [{ product_id: water.id, qty: 3 }], payment_method: 'cash', tendered: 1000, discount_pct: 33,
  }, admin)).data;
  const item = sale.items[0];
  let last;
  for (let i = 0; i < 3; i++) {
    last = (await pos.call('POST', `/api/sales/${sale.id}/refunds`, {
      items: [{ sale_item_id: item.id, qty: 1 }], method: 'cash', reason: 'split',
    }, admin)).data;
  }
  assert.equal(last.refunded_amount, sale.total);
});

test('cannot oversell tracked stock', async () => {
  const admin = await pos.login('admin', '1234');
  const charger = await findProduct(admin, 'HH-002');
  const r = await pos.call('POST', '/api/sales', {
    items: [{ product_id: charger.id, qty: charger.stock + 1 }], payment_method: 'card',
  }, admin);
  assert.equal(r.status, 400);
  assert.match(r.data.error, /Not enough stock/);
});

test('cashier limits and blind till count', async () => {
  const admin = await pos.login('admin', '1234');
  assert.equal((await pos.call('POST', '/api/users', { username: 'sam', name: 'Sam', pin: '2468', role: 'cashier' }, admin)).status, 200);
  const cashier = await pos.login('sam', '2468');
  const water = await findProduct(cashier, 'DRK-002');
  const big = await pos.call('POST', '/api/sales', {
    items: [{ product_id: water.id, qty: 1 }], payment_method: 'card', discount_pct: 50,
  }, cashier);
  assert.equal(big.status, 403);
  assert.equal((await pos.call('GET', '/api/reports/summary', null, cashier)).status, 403);
  assert.equal((await pos.call('POST', '/api/sales/1/refunds', { reason: 'x', method: 'cash', items: [] }, cashier)).status, 403);
  assert.equal((await pos.call('GET', '/api/shifts/current', null, cashier)).data.shift.expected_cash, null);
  assert.notEqual((await pos.call('GET', '/api/shifts/current', null, admin)).data.shift.expected_cash, null);
});

test('till close works out expected cash and variance', async () => {
  const admin = await pos.login('admin', '1234');
  await pos.call('POST', '/api/shifts/current/movements', { type: 'paid_out', amount: 250, reason: 'milk' }, admin);
  await pos.call('POST', '/api/shifts/current/movements', { type: 'paid_in', amount: 1000, reason: 'change' }, admin);
  const current = (await pos.call('GET', '/api/shifts/current', null, admin)).data.shift;
  const expected = current.opening_float + current.cash_sales.total - current.cash_refunds.total + 1000 - 250;
  assert.equal(current.expected_cash, expected);
  const closed = await pos.call('POST', '/api/shifts/current/close', { counted_cash: expected - 50 }, admin);
  assert.equal(closed.data.status, 'closed');
  assert.equal(closed.data.variance, -50);
  assert.equal((await pos.call('GET', '/api/shifts/current', null, admin)).data.shift, null);
});

test('last active manager cannot be disabled', async () => {
  const admin = await pos.login('admin', '1234');
  assert.equal((await pos.call('PUT', '/api/users/1', { active: false }, admin)).status, 400);
});

test('report and CSV export include refunds', async () => {
  const admin = await pos.login('admin', '1234');
  const r = (await pos.call('GET', '/api/reports/summary', null, admin)).data;
  assert.ok(r.sales.count >= 2);
  assert.ok(r.refunds.count >= 5);
  assert.equal(r.net.total, r.sales.total - r.refunds.total);
  const csv = await pos.call('GET', '/api/reports/sales.csv', null, admin);
  assert.match(csv.data, /Receipt,Date/);
  assert.match(csv.data, /partially_refunded|refunded/);
});
