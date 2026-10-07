// Shared by the browser (cart preview) and the server (authoritative totals).
// All money values are integers in minor units (e.g. pence). Rates are percentages.
export function priceLines(lines, { discountPct = 0, taxInclusive = true } = {}) {
  const pct = Math.min(Math.max(Number(discountPct) || 0, 0), 100);
  let subtotal = 0, discount = 0, tax = 0, total = 0;
  const out = lines.map((line) => {
    const gross = line.unitPrice * line.qty;
    const lineDiscount = Math.round((gross * pct) / 100);
    const net = gross - lineDiscount;
    const rate = Number(line.taxRate) || 0;
    const lineTax = taxInclusive
      ? Math.round((net * rate) / (100 + rate))
      : Math.round((net * rate) / 100);
    const lineTotal = taxInclusive ? net : net + lineTax;
    subtotal += gross;
    discount += lineDiscount;
    tax += lineTax;
    total += lineTotal;
    return { ...line, discount: lineDiscount, tax: lineTax, total: lineTotal };
  });
  return { lines: out, subtotal, discount, tax, total };
}
