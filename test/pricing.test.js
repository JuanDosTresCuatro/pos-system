import { test } from 'node:test';
import assert from 'node:assert/strict';
import { priceLines } from '../public/js/pricing.js';

test('tax-inclusive prices extract tax from the gross', () => {
  const r = priceLines([{ unitPrice: 120, qty: 1, taxRate: 20 }], { taxInclusive: true });
  assert.deepEqual([r.subtotal, r.tax, r.total], [120, 20, 120]);
});

test('tax-exclusive prices add tax on top', () => {
  const r = priceLines([{ unitPrice: 100, qty: 3, taxRate: 20 }], { taxInclusive: false });
  assert.deepEqual([r.subtotal, r.tax, r.total], [300, 60, 360]);
});

test('discount applies before tax and is spread across lines', () => {
  const r = priceLines(
    [{ unitPrice: 120, qty: 2, taxRate: 20 }, { unitPrice: 395, qty: 1, taxRate: 0 }],
    { discountPct: 10, taxInclusive: true },
  );
  assert.equal(r.discount, 24 + 40);
  assert.equal(r.tax, 36);
  assert.equal(r.total, 571);
});

test('discount is clamped to 0..100', () => {
  assert.equal(priceLines([{ unitPrice: 100, qty: 1, taxRate: 0 }], { discountPct: 150 }).total, 0);
  assert.equal(priceLines([{ unitPrice: 100, qty: 1, taxRate: 0 }], { discountPct: -5 }).total, 100);
});
