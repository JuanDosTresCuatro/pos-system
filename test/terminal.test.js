import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startServer } from './helpers.js';
import { startMockStripe } from './mock-stripe.js';

let pos;
let stripe;
let admin;
let cola;

before(async () => {
  stripe = await startMockStripe();
  pos = await startServer({ STRIPE_SECRET_KEY: 'sk_test_mock', STRIPE_API_BASE: stripe.base });
  admin = await pos.login('admin', '1234');
  await pos.call('PUT', '/api/settings', { card_mode: 'stripe', stripe_reader_id: 'tmr_mock1' }, admin);
  await pos.call('POST', '/api/shifts', { opening_float: 0 }, admin);
  cola = (await pos.call('GET', '/api/products', null, admin)).data.find((p) => p.sku === 'DRK-001');
});
after(() => { pos.stop(); stripe.close(); });

const startPayment = (qty = 2) =>
  pos.call('POST', '/api/terminal/payments', { items: [{ product_id: cola.id, qty }], reader_id: 'tmr_mock1' }, admin);

test('terminal status lists readers in test mode', async () => {
  const s = (await pos.call('GET', '/api/terminal/status', null, admin)).data;
  assert.equal(s.configured, true);
  assert.equal(s.testMode, true);
  assert.equal(s.readers[0].id, 'tmr_mock1');
});

test('manual card sales are blocked when the terminal is in use', async () => {
  const r = await pos.call('POST', '/api/sales', { items: [{ product_id: cola.id, qty: 1 }], payment_method: 'card' }, admin);
  assert.equal(r.status, 400);
});

let paidSale;

test('declined card, retry, then approved card records the sale', async () => {
  const start = await startPayment(2);
  assert.equal(start.status, 200);
  assert.equal(start.data.status, 'waiting');
  assert.equal(start.data.amount, 240);
  const id = start.data.id;

  assert.equal((await startPayment(1)).status, 409, 'second payment on a busy reader is refused');

  await pos.call('POST', `/api/terminal/payments/${id}/simulate`, { decline: true }, admin);
  const declined = (await pos.call('GET', `/api/terminal/payments/${id}`, null, admin)).data;
  assert.equal(declined.status, 'declined');
  assert.match(declined.message, /declined/);
  assert.equal(declined.sale, null);

  assert.equal((await pos.call('POST', `/api/terminal/payments/${id}/retry`, null, admin)).data.status, 'waiting');
  await pos.call('POST', `/api/terminal/payments/${id}/simulate`, { decline: false }, admin);
  const done = (await pos.call('GET', `/api/terminal/payments/${id}`, null, admin)).data;
  assert.equal(done.status, 'succeeded');
  assert.equal(done.sale.total, 240);
  assert.equal(done.sale.payment_method, 'card');
  assert.equal(done.sale.card_last4, '4242');
  assert.equal(done.sale.card_aid, 'A0000000031010');
  assert.equal(done.sale.card_auth_code, '123456');
  assert.match(done.sale.stripe_payment_intent, /^pi_/);

  // Polling again must not record the sale twice.
  const again = (await pos.call('GET', `/api/terminal/payments/${id}`, null, admin)).data;
  assert.equal(again.sale.id, done.sale.id);
  const sales = (await pos.call('GET', '/api/sales', null, admin)).data.filter((s) => s.payment_method === 'card');
  assert.equal(sales.length, 1);
  paidSale = done.sale;
});

test('card refunds go back through Stripe, partial then full', async () => {
  const item = paidSale.items[0];
  const part = await pos.call('POST', `/api/sales/${paidSale.id}/refunds`, {
    items: [{ sale_item_id: item.id, qty: 1 }], method: 'stripe', reason: 'faulty',
  }, admin);
  assert.equal(part.status, 200);
  assert.equal(part.data.status, 'partially_refunded');
  assert.match(part.data.refunds[0].provider_ref, /^re_/);
  assert.equal(stripe.refunds.at(-1).amount, 120);

  const rest = await pos.call('POST', `/api/sales/${paidSale.id}/refunds`, {
    items: [{ sale_item_id: item.id, qty: 1 }], method: 'stripe', reason: 'faulty',
  }, admin);
  assert.equal(rest.data.status, 'refunded');
  assert.equal(stripe.refunds.reduce((a, r) => a + r.amount, 0), 240);
});

test('cashier can cancel a waiting payment and no sale is recorded', async () => {
  const start = await startPayment(1);
  const cancelled = (await pos.call('POST', `/api/terminal/payments/${start.data.id}/cancel`, null, admin)).data;
  assert.equal(cancelled.status, 'canceled');
  assert.equal(cancelled.sale, null);
  assert.equal(stripe.readers.get('tmr_mock1').action, null);
});

test('cancel after the customer already paid records the sale instead', async () => {
  const start = await startPayment(1);
  // Customer taps just before the cashier presses cancel.
  const reader = stripe.readers.get('tmr_mock1');
  const pi = stripe.intents.get(reader.action.process_payment_intent.payment_intent);
  pi.status = 'succeeded';
  pi.latest_charge = { payment_method_details: { card_present: { brand: 'mastercard', last4: '4444' } } };
  const r = (await pos.call('POST', `/api/terminal/payments/${start.data.id}/cancel`, null, admin)).data;
  assert.equal(r.status, 'succeeded');
  assert.equal(r.sale.card_last4, '4444');
});

test('till cannot close while a card payment is in progress', async () => {
  const start = await startPayment(1);
  const close = await pos.call('POST', '/api/shifts/current/close', { counted_cash: 0 }, admin);
  assert.equal(close.status, 409);
  await pos.call('POST', `/api/terminal/payments/${start.data.id}/cancel`, null, admin);
  const shift = (await pos.call('GET', '/api/shifts/current', null, admin)).data.shift;
  assert.equal(shift.card_sales.count, 2);
  assert.equal(shift.card_refunds.total, 240);
  assert.equal((await pos.call('POST', '/api/shifts/current/close', { counted_cash: 0 }, admin)).data.variance, 0);
});
