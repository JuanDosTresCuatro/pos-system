import { priceLines } from './pricing.js';

// ---------- small helpers
const $ = (sel, el = document) => el.querySelector(sel);
const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const pad = (n) => String(n).padStart(2, '0');
const receiptNo = (id) => String(id).padStart(6, '0');

const session = {
  get: () => { try { return sessionStorage.getItem('pos_token'); } catch { return null; } },
  set: (t) => { try { sessionStorage.setItem('pos_token', t); } catch { /* storage unavailable */ } },
  clear: () => { try { sessionStorage.removeItem('pos_token'); } catch { /* storage unavailable */ } },
};

const local = {
  get: (k) => { try { return localStorage.getItem(k); } catch { return null; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* storage unavailable */ } },
};

const state = {
  token: session.get(),
  user: null,
  settings: {},
  products: [],
  categories: [],
  cart: [],
  discountPct: 0,
  category: null,
  search: '',
  view: 'sell',
  shift: null,
  terminal: null,
};

const isAdmin = () => state.user?.role === 'admin';
const taxInclusive = () => state.settings.tax_inclusive === '1';

// ---------- API
async function api(method, url, body) {
  const res = await fetch(url, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(state.token && { Authorization: `Bearer ${state.token}` }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.status === 401 && state.user) {
    endSession('Your session has ended. Please log in again.');
    throw new Error('Session ended');
  }
  const data = res.headers.get('content-type')?.includes('json') ? await res.json() : await res.text();
  if (!res.ok) throw new Error(data?.error || `Request failed (${res.status})`);
  return data;
}

// ---------- money and dates
let moneyFmt = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' });
let digits = 2;

function setupFormats() {
  try {
    moneyFmt = new Intl.NumberFormat(state.settings.locale, { style: 'currency', currency: state.settings.currency });
  } catch {
    moneyFmt = new Intl.NumberFormat('en-GB', { style: 'currency', currency: 'GBP' });
  }
  digits = moneyFmt.resolvedOptions().maximumFractionDigits;
}
const money = (minor) => moneyFmt.format((minor || 0) / 10 ** digits);
const toMinor = (v) => Math.round(parseFloat(v) * 10 ** digits);
const toMajor = (minor) => ((minor || 0) / 10 ** digits).toFixed(digits);
const fmtDate = (iso) => (iso ? new Date(iso).toLocaleString(state.settings.locale || undefined, { dateStyle: 'short', timeStyle: 'short' }) : '');
const dateValue = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const parseDateValue = (v) => { const [y, m, d] = v.split('-').map(Number); return new Date(y, m - 1, d); };

function rangeQuery(fromValue, toValue) {
  const from = parseDateValue(fromValue);
  const to = parseDateValue(toValue);
  to.setDate(to.getDate() + 1);
  return `from=${encodeURIComponent(from.toISOString())}&to=${encodeURIComponent(to.toISOString())}`;
}

const PRESETS = {
  today: () => { const d = new Date(); return [d, d]; },
  yesterday: () => { const d = new Date(); d.setDate(d.getDate() - 1); return [d, d]; },
  week: () => { const t = new Date(); const f = new Date(); f.setDate(f.getDate() - 6); return [f, t]; },
  month: () => { const t = new Date(); return [new Date(t.getFullYear(), t.getMonth(), 1), t]; },
};

function rangeBar() {
  const today = dateValue(new Date());
  return `<div class="toolbar range">
    <label>From <input type="date" name="from" value="${today}"></label>
    <label>To <input type="date" name="to" value="${today}"></label>
    <div class="seg">
      <button type="button" data-preset="today">Today</button>
      <button type="button" data-preset="yesterday">Yesterday</button>
      <button type="button" data-preset="week">Last 7 days</button>
      <button type="button" data-preset="month">This month</button>
    </div>
  </div>`;
}

function wireRange(root, onChange) {
  const from = $('[name=from]', root);
  const to = $('[name=to]', root);
  $$('[data-preset]', root).forEach((b) => b.addEventListener('click', () => {
    const [f, t] = PRESETS[b.dataset.preset]();
    from.value = dateValue(f);
    to.value = dateValue(t);
    onChange();
  }));
  from.addEventListener('change', onChange);
  to.addEventListener('change', onChange);
  return () => {
    if (from.value > to.value) to.value = from.value;
    return { query: rangeQuery(from.value, to.value), from: from.value, to: to.value };
  };
}

// ---------- UI primitives
function toast(message, type = 'info') {
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = message;
  $('#toast-root').append(el);
  setTimeout(() => el.classList.add('hide'), 3200);
  setTimeout(() => el.remove(), 3600);
}

function openModal(html, { wide = false, locked = false } = {}) {
  const root = $('#modal-root');
  const wrap = document.createElement('div');
  wrap.className = 'overlay';
  wrap.innerHTML = `<div class="modal${wide ? ' wide' : ''}" role="dialog" aria-modal="true">${html}</div>`;
  root.append(wrap);
  const onKey = (e) => { if (!locked && e.key === 'Escape' && root.lastElementChild === wrap) close(); };
  const close = () => { wrap.remove(); document.removeEventListener('keydown', onKey); };
  document.addEventListener('keydown', onKey);
  wrap.addEventListener('mousedown', (e) => { if (!locked && e.target === wrap) close(); });
  $$('[data-close]', wrap).forEach((b) => b.addEventListener('click', close));
  setTimeout(() => ($('[autofocus]', wrap) || $('input, select, button', wrap))?.focus(), 0);
  return { el: wrap, close };
}

function confirmModal(title, text, { confirmLabel = 'Confirm', danger = false } = {}) {
  return new Promise((resolve) => {
    const m = openModal(`<h2>${esc(title)}</h2><p>${esc(text)}</p>
      <div class="actions"><button data-close>Cancel</button><button class="${danger ? 'danger' : 'primary'}" id="ok">${esc(confirmLabel)}</button></div>`);
    $('#ok', m.el).addEventListener('click', () => { m.close(); resolve(true); });
    new MutationObserver((_, obs) => { if (!m.el.isConnected) { obs.disconnect(); resolve(false); } })
      .observe($('#modal-root'), { childList: true });
  });
}

// Wraps a form submit so the button is disabled while the request runs.
function onSubmit(form, handler) {
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const buttons = $$('button', form);
    buttons.forEach((b) => (b.disabled = true));
    try {
      await handler(Object.fromEntries(new FormData(form)));
    } catch (err) {
      if (err.message !== 'Session ended') toast(err.message, 'error');
    } finally {
      buttons.forEach((b) => (b.disabled = false));
    }
  });
}

// ---------- login and shell
async function boot() {
  if (state.token) {
    try {
      const me = await api('GET', '/api/me');
      return startSession(me.user, me.settings);
    } catch {
      session.clear();
      state.token = null;
    }
  }
  renderLogin();
}

async function renderLogin(message = '') {
  let storeName = 'Point of Sale';
  try { storeName = (await api('GET', '/api/store')).store_name; } catch { /* server unreachable; show form anyway */ }
  $('#app').innerHTML = `<div class="login">
    <form class="card" id="loginForm" autocomplete="off">
      <h1>${esc(storeName)}</h1>
      <p class="muted">Sign in to start selling</p>
      ${message ? `<p class="notice">${esc(message)}</p>` : ''}
      <label>Username <input name="username" required autofocus autocapitalize="none"></label>
      <label>PIN <input name="pin" type="password" inputmode="numeric" required></label>
      <button class="primary block" type="submit">Sign in</button>
    </form>
  </div>`;
  $('[name=username]').focus();
  onSubmit($('#loginForm'), async (data) => {
    const res = await api('POST', '/api/login', data);
    state.token = res.token;
    session.set(res.token);
    startSession(res.user, res.settings);
  });
}

function startSession(user, settings) {
  state.user = user;
  state.settings = settings;
  setupFormats();
  renderShell();
  go(state.view);
}

function endSession(message) {
  session.clear();
  Object.assign(state, { token: null, user: null, cart: [], discountPct: 0 });
  $('#modal-root').innerHTML = '';
  renderLogin(message);
}

const VIEWS = [
  { id: 'sell', label: 'Sell', render: renderSell },
  { id: 'sales', label: 'Sales', render: renderSales },
  { id: 'till', label: 'Till', render: renderTill },
  { id: 'products', label: 'Products', render: renderProducts },
  { id: 'reports', label: 'Reports', render: renderReports, admin: true },
  { id: 'users', label: 'Staff', render: renderUsers, admin: true },
  { id: 'settings', label: 'Settings', render: renderSettings, admin: true },
  { id: 'audit', label: 'Audit log', render: renderAudit, admin: true },
  { id: 'system', label: 'System', render: renderSystem, admin: true },
];

function renderShell() {
  const views = VIEWS.filter((v) => !v.admin || isAdmin());
  $('#app').innerHTML = `<header class="top">
      <div class="brand">${esc(state.settings.store_name)}</div>
      <nav>${views.map((v) => `<button data-view="${v.id}">${v.label}</button>`).join('')}</nav>
      <div class="who">
        <span>${esc(state.user.name)} <span class="role">${state.user.role === 'admin' ? 'Manager' : 'Cashier'}</span></span>
        <button id="pinBtn" class="ghost">Change PIN</button>
        <button id="logoutBtn" class="ghost">Sign out</button>
      </div>
    </header>
    <main id="main"></main>`;
  $$('nav button').forEach((b) => b.addEventListener('click', () => go(b.dataset.view)));
  $('#logoutBtn').addEventListener('click', async () => {
    if (state.cart.length && !(await confirmModal('Sign out?', 'The current cart will be cleared.', { confirmLabel: 'Sign out' }))) return;
    try { await api('POST', '/api/logout'); } catch { /* signing out anyway */ }
    endSession();
  });
  $('#pinBtn').addEventListener('click', changePinModal);
}

async function go(viewId) {
  const view = VIEWS.find((v) => v.id === viewId && (!v.admin || isAdmin())) || VIEWS[0];
  state.view = view.id;
  $$('nav button').forEach((b) => b.classList.toggle('active', b.dataset.view === view.id));
  const main = $('#main');
  main.className = `view-${view.id}`;
  main.innerHTML = '<p class="loading">Loading…</p>';
  try {
    await view.render(main);
  } catch (err) {
    if (err.message !== 'Session ended') main.innerHTML = `<p class="notice error">${esc(err.message)}</p>`;
  }
}

function changePinModal() {
  const m = openModal(`<h2>Change your PIN</h2>
    <form id="pinForm">
      <label>Current PIN <input name="current" type="password" inputmode="numeric" required autofocus></label>
      <label>New PIN (4 to 8 digits) <input name="pin" type="password" inputmode="numeric" pattern="\\d{4,8}" required></label>
      <label>Repeat new PIN <input name="repeat" type="password" inputmode="numeric" required></label>
      <div class="actions"><button type="button" data-close>Cancel</button><button class="primary">Save</button></div>
    </form>`);
  onSubmit($('#pinForm', m.el), async (d) => {
    if (d.pin !== d.repeat) throw new Error('The new PINs do not match');
    await api('POST', '/api/me/pin', d);
    m.close();
    toast('PIN changed', 'success');
  });
}

// ---------- SELL
async function loadCatalog() {
  [state.products, state.categories] = await Promise.all([api('GET', '/api/products'), api('GET', '/api/categories')]);
  // Keep cart lines in sync with current price and stock.
  state.cart = state.cart
    .map((l) => ({ ...l, product: state.products.find((p) => p.id === l.product.id) }))
    .filter((l) => l.product);
}

const terminalMode = () => state.settings.card_mode === 'stripe';

async function renderSell(main) {
  const [, shiftRes, terminal, activeCard] = await Promise.all([
    loadCatalog(),
    api('GET', '/api/shifts/current'),
    terminalMode() ? api('GET', '/api/terminal/status') : null,
    terminalMode() ? api('GET', '/api/terminal/payments/active') : [],
  ]);
  state.shift = shiftRes.shift;
  state.terminal = terminal;
  main.innerHTML = `<section class="catalog">
      <div class="search-row">
        <input id="search" type="search" placeholder="Scan a barcode or search by name or SKU" autocomplete="off" value="${esc(state.search)}">
      </div>
      <div class="chips" id="chips"></div>
      <div class="grid" id="grid"></div>
    </section>
    <aside class="cart">
      <div class="cart-head"><h2>Current sale</h2><button id="clearCart" class="ghost">Clear</button></div>
      <div class="till-bar" id="tillBar"></div>
      <div class="cart-lines" id="cartLines"></div>
      <div class="cart-foot">
        <label class="inline">Discount %
          <input id="disc" type="number" min="0" max="100" step="0.5" value="${state.discountPct || ''}" placeholder="0">
        </label>
        <div class="totals" id="totals"></div>
        <div class="pay">
          <button class="primary big" id="payCash">Cash</button>
          <button class="primary big" id="payCard">Card</button>
        </div>
      </div>
    </aside>`;

  const search = $('#search');
  search.addEventListener('input', () => { state.search = search.value; renderGrid(); });
  search.addEventListener('keydown', (e) => {
    if (e.key !== 'Enter') return;
    e.preventDefault();
    const code = search.value.trim().toLowerCase();
    if (!code) return;
    const exact = state.products.find((p) => p.barcode?.toLowerCase() === code || p.sku.toLowerCase() === code);
    const list = filteredProducts();
    const hit = exact || (list.length === 1 ? list[0] : null);
    if (hit) {
      addToCart(hit);
      search.value = state.search = '';
      renderGrid();
    } else {
      toast(list.length ? 'More than one match. Tap the product.' : 'No product matches that code', 'error');
      search.select();
    }
  });

  $('#chips').addEventListener('click', (e) => {
    const b = e.target.closest('[data-cat]');
    if (!b) return;
    state.category = b.dataset.cat ? Number(b.dataset.cat) : null;
    renderChips();
    renderGrid();
  });
  $('#grid').addEventListener('click', (e) => {
    const tile = e.target.closest('[data-id]');
    if (tile) addToCart(state.products.find((p) => p.id === Number(tile.dataset.id)));
  });
  $('#cartLines').addEventListener('click', (e) => {
    const b = e.target.closest('button[data-act]');
    if (!b) return;
    const i = Number(b.dataset.i);
    if (b.dataset.act === 'inc') setQty(i, state.cart[i].qty + 1);
    if (b.dataset.act === 'dec') setQty(i, state.cart[i].qty - 1);
    if (b.dataset.act === 'del') setQty(i, 0);
  });
  $('#cartLines').addEventListener('change', (e) => {
    if (e.target.dataset.act === 'set') setQty(Number(e.target.dataset.i), parseInt(e.target.value, 10) || 0);
  });
  $('#disc').addEventListener('input', (e) => {
    const v = Math.min(Math.max(parseFloat(e.target.value) || 0, 0), 100);
    const limit = Number(state.settings.max_cashier_discount);
    if (!isAdmin() && v > limit) {
      toast(`Discounts above ${limit}% need a manager`, 'error');
      e.target.value = limit;
      state.discountPct = limit;
    } else {
      state.discountPct = v;
    }
    renderCart();
  });
  $('#clearCart').addEventListener('click', async () => {
    if (!state.cart.length) return;
    if (await confirmModal('Clear the sale?', 'All items will be removed from the cart.', { confirmLabel: 'Clear', danger: true })) {
      state.cart = [];
      state.discountPct = 0;
      $('#disc').value = '';
      renderCart();
    }
  });
  $('#payCash').addEventListener('click', payCash);
  $('#payCard').addEventListener('click', () => (terminalMode() ? payTerminal() : payCard()));
  $('#tillBar').addEventListener('click', (e) => {
    if (e.target.closest('#openTill')) openTillModal(() => go('sell'));
    if (e.target.closest('#gotoTill')) go('till');
  });

  renderTillBar();
  renderChips();
  renderGrid();
  renderCart();
  search.focus();
  // Pick up a card payment left in progress (for example after a page reload).
  if (activeCard.length) terminalModal(activeCard[0]);
}

function renderTillBar() {
  const s = state.shift;
  $('#tillBar').innerHTML = s
    ? `<span class="dot ok"></span> Till open since ${new Date(s.opened_at).toLocaleTimeString(state.settings.locale || undefined, { timeStyle: 'short' })}
       <button class="ghost small-btn" id="gotoTill">Till</button>`
    : '<span class="dot"></span> Till closed. Open it to take payments. <button class="primary small-btn" id="openTill">Open till</button>';
}

function renderChips() {
  const chip = (id, name) => `<button data-cat="${id ?? ''}" class="${state.category === id ? 'active' : ''}">${esc(name)}</button>`;
  $('#chips').innerHTML = chip(null, 'All') + state.categories.map((c) => chip(c.id, c.name)).join('');
}

function filteredProducts() {
  const q = state.search.trim().toLowerCase();
  return state.products.filter((p) =>
    (!state.category || p.category_id === state.category) &&
    (!q || p.name.toLowerCase().includes(q) || p.sku.toLowerCase().includes(q) || (p.barcode || '').toLowerCase().includes(q)));
}

function renderGrid() {
  const list = filteredProducts();
  $('#grid').innerHTML = list.length
    ? list.map((p) => `<button class="tile${p.track_stock && p.stock <= 0 ? ' out' : ''}" data-id="${p.id}">
        <span class="tile-name">${esc(p.name)}</span>
        <span class="tile-price">${money(p.price)}</span>
        ${p.track_stock ? `<span class="tile-stock${p.stock <= p.low_stock ? ' low' : ''}">${p.stock} in stock</span>` : ''}
      </button>`).join('')
    : '<p class="empty">No products found</p>';
}

function stockAllows(product, qty) {
  if (!product.track_stock || state.settings.allow_negative_stock === '1' || qty <= product.stock) return true;
  toast(`Only ${product.stock} of ${product.name} in stock`, 'error');
  return false;
}

function addToCart(product) {
  if (!product) return;
  const i = state.cart.findIndex((l) => l.product.id === product.id);
  if (i >= 0) return setQty(i, state.cart[i].qty + 1);
  if (!stockAllows(product, 1)) return;
  state.cart.push({ product, qty: 1 });
  renderCart();
}

function setQty(i, qty) {
  const line = state.cart[i];
  if (!line) return;
  if (qty <= 0) state.cart.splice(i, 1);
  else if (stockAllows(line.product, qty)) line.qty = Math.min(qty, 10000);
  renderCart();
}

function cartTotals() {
  return priceLines(
    state.cart.map((l) => ({ unitPrice: l.product.price, qty: l.qty, taxRate: l.product.tax_rate })),
    { discountPct: state.discountPct, taxInclusive: taxInclusive() },
  );
}

function renderCart() {
  const t = cartTotals();
  $('#cartLines').innerHTML = state.cart.length
    ? state.cart.map((l, i) => `<div class="line">
        <div class="line-info"><div class="line-name">${esc(l.product.name)}</div><div class="muted">${money(l.product.price)} each</div></div>
        <div class="qty">
          <button data-act="dec" data-i="${i}" aria-label="One less">&minus;</button>
          <input data-act="set" data-i="${i}" value="${l.qty}" inputmode="numeric" aria-label="Quantity">
          <button data-act="inc" data-i="${i}" aria-label="One more">+</button>
        </div>
        <div class="line-total">${money(l.product.price * l.qty)}</div>
        <button class="icon" data-act="del" data-i="${i}" aria-label="Remove">&times;</button>
      </div>`).join('')
    : '<p class="empty">Cart is empty.<br>Scan or tap a product to add it.</p>';
  const label = esc(state.settings.tax_label);
  $('#totals').innerHTML = `
    <div><span>Subtotal</span><span>${money(t.subtotal)}</span></div>
    ${t.discount ? `<div><span>Discount (${state.discountPct}%)</span><span>&minus;${money(t.discount)}</span></div>` : ''}
    <div><span>${label}${taxInclusive() ? ' (included)' : ''}</span><span>${money(t.tax)}</span></div>
    <div class="grand"><span>Total</span><span>${money(t.total)}</span></div>`;
  $('#payCash').disabled = $('#payCard').disabled = !state.cart.length || !state.shift;
}

function payCash() {
  const t = cartTotals();
  const unit = 10 ** digits;
  const suggestions = [...new Set([t.total, ...[5, 10, 20, 50, 100].map((n) => Math.ceil(t.total / (n * unit)) * n * unit)])]
    .filter((v) => v >= t.total).sort((a, b) => a - b).slice(0, 5);
  const m = openModal(`<h2>Cash payment</h2>
    <p class="amount">${money(t.total)}</p>
    <form id="cashForm">
      <label>Amount tendered <input name="tendered" type="number" min="0" step="${1 / unit}" required autofocus></label>
      <div class="quick">${suggestions.map((v) => `<button type="button" data-v="${v}">${money(v)}</button>`).join('')}</div>
      <p id="changeOut" class="change"></p>
      <div class="actions"><button type="button" data-close>Cancel</button><button class="primary">Complete sale</button></div>
    </form>`);
  const input = $('[name=tendered]', m.el);
  const update = () => {
    const v = toMinor(input.value);
    const out = $('#changeOut', m.el);
    out.textContent = Number.isNaN(v) ? '' : v >= t.total ? `Change due: ${money(v - t.total)}` : `Short by ${money(t.total - v)}`;
    out.classList.toggle('short', v < t.total);
  };
  input.addEventListener('input', update);
  $$('.quick button', m.el).forEach((b) => b.addEventListener('click', () => { input.value = toMajor(Number(b.dataset.v)); update(); }));
  onSubmit($('#cashForm', m.el), async () => {
    const tendered = toMinor(input.value);
    if (!(tendered >= t.total)) throw new Error('Amount tendered is less than the total');
    await completeSale('cash', tendered, m);
  });
}

function payCard() {
  const t = cartTotals();
  const m = openModal(`<h2>Card payment</h2>
    <p class="amount">${money(t.total)}</p>
    <p class="muted">Take payment on the card terminal. Confirm only after the terminal shows the payment as approved.</p>
    <form id="cardForm"><div class="actions"><button type="button" data-close>Cancel</button><button class="primary" autofocus>Payment approved</button></div></form>`);
  onSubmit($('#cardForm', m.el), () => completeSale('card', t.total, m));
}

async function completeSale(method, tendered, modal) {
  const sale = await api('POST', '/api/sales', {
    items: state.cart.map((l) => ({ product_id: l.product.id, qty: l.qty })),
    discount_pct: state.discountPct,
    payment_method: method,
    tendered,
  });
  modal.close();
  await finishSale(sale);
}

async function finishSale(sale) {
  state.cart = [];
  state.discountPct = 0;
  await go('sell');
  showReceipt(sale);
}

function openTillModal(onDone) {
  const m = openModal(`<h2>Open the till</h2>
    <form id="openForm">
      <label>Opening float (cash in the drawer now) <input name="float" type="number" min="0" step="${1 / 10 ** digits}" value="0" required autofocus></label>
      <div class="actions"><button type="button" data-close>Cancel</button><button class="primary">Open till</button></div>
    </form>`);
  onSubmit($('#openForm', m.el), async (d) => {
    await api('POST', '/api/shifts', { opening_float: toMinor(d.float) });
    m.close();
    toast('Till opened', 'success');
    onDone();
  });
}

// ---------- card terminal (Stripe Terminal)
const ACTIVE_CARD = ['starting', 'waiting', 'declined'];

function chooseReader() {
  const readers = state.terminal?.readers || [];
  const ids = readers.map((r) => r.id);
  const saved = local.get('pos_reader');
  if (ids.includes(saved)) return saved;
  if (ids.includes(state.terminal.defaultReader)) return state.terminal.defaultReader;
  return ids[0] || null;
}

async function payTerminal() {
  const t = state.terminal;
  if (!t?.configured) return toast('The card terminal is not set up. A manager can fix this in Settings.', 'error');
  if (t.error) return toast(`Card terminal: ${t.error}`, 'error');
  const readerId = chooseReader();
  if (!readerId) return toast('No card reader is registered. A manager can add one in Settings.', 'error');
  const button = $('#payCard');
  button.disabled = true;
  try {
    const cp = await api('POST', '/api/terminal/payments', {
      items: state.cart.map((l) => ({ product_id: l.product.id, qty: l.qty })),
      discount_pct: state.discountPct,
      reader_id: readerId,
    });
    terminalModal(cp);
  } catch (err) {
    if (err.message !== 'Session ended') toast(err.message, 'error');
  } finally {
    button.disabled = !state.cart.length || !state.shift;
  }
}

function terminalModal(initial) {
  const reader = state.terminal?.readers?.find((r) => r.id === initial.reader_id);
  const readerName = esc(reader?.label || 'the card reader');
  const m = openModal(`<h2>Card payment</h2>
    <p class="amount">${money(initial.amount)}</p>
    <div id="termState" class="term-state"></div>
    <div class="actions" id="termActions"></div>`, { locked: true });
  let current = initial;
  let shown = '';
  let timer = null;
  let done = false;

  const finish = () => { done = true; clearTimeout(timer); m.close(); };

  const render = (cp) => {
    current = cp;
    if (cp.status === 'succeeded') { finish(); toast('Card payment approved', 'success'); finishSale(cp.sale); return; }
    if (cp.status === 'canceled' || cp.status === 'error') { finish(); toast(cp.message || 'Card payment cancelled', 'error'); return; }
    const key = `${cp.status}|${cp.message}`;
    if (key === shown) return;
    shown = key;
    const test = state.terminal?.testMode;
    if (cp.status === 'declined') {
      $('#termState', m.el).innerHTML = `<p class="notice error">${esc(cp.message || 'The card was declined')}</p>
        <p class="muted">Ask the customer to try again or use another card or payment method.</p>`;
      $('#termActions', m.el).innerHTML = `<button data-act="cancel">Cancel payment</button><button class="primary" data-act="retry">Try again</button>`;
    } else {
      $('#termState', m.el).innerHTML = `<div class="waiting"><span class="spinner"></span>
        <span>Ask the customer to tap, insert or swipe their card on <strong>${readerName}</strong>.</span></div>`;
      $('#termActions', m.el).innerHTML = `${test ? `<span class="test-tag">Test mode</span>
          <button data-act="approve">Simulate approved card</button><button data-act="decline">Simulate declined card</button>
          <span class="spacer"></span>` : ''}<button class="danger" data-act="cancel">Cancel payment</button>`;
    }
  };

  const poll = async () => {
    if (done) return;
    try {
      render(await api('GET', `/api/terminal/payments/${current.id}`));
    } catch (err) {
      if (err.message === 'Session ended') { done = true; return; }
      // Network blips are normal; keep checking. The server also checks in the background.
    }
    if (!done && current.status !== 'declined') timer = setTimeout(poll, 1500);
  };

  $('#termActions', m.el).addEventListener('click', async (e) => {
    const b = e.target.closest('button[data-act]');
    if (!b) return;
    $$('#termActions button', m.el).forEach((x) => (x.disabled = true));
    const act = b.dataset.act;
    try {
      let next;
      if (act === 'cancel') next = await api('POST', `/api/terminal/payments/${current.id}/cancel`);
      if (act === 'retry') next = await api('POST', `/api/terminal/payments/${current.id}/retry`);
      if (act === 'approve' || act === 'decline') {
        next = await api('POST', `/api/terminal/payments/${current.id}/simulate`, { decline: act === 'decline' });
      }
      shown = '';
      render(next);
      if (act === 'retry' && !done) { clearTimeout(timer); timer = setTimeout(poll, 1500); }
    } catch (err) {
      if (err.message !== 'Session ended') toast(err.message, 'error');
      $$('#termActions button', m.el).forEach((x) => (x.disabled = false));
    }
  });

  render(initial);
  if (ACTIVE_CARD.includes(initial.status) && initial.status !== 'declined') timer = setTimeout(poll, 1500);
}

// ---------- receipts
function receiptHtml(s) {
  const st = state.settings;
  const label = esc(st.tax_label);
  return `<div class="receipt">
    <div class="r-head">
      <strong>${esc(st.store_name)}</strong>
      ${st.store_address ? `<div>${esc(st.store_address).replace(/\n/g, '<br>')}</div>` : ''}
      ${st.tax_number ? `<div>${label} no. ${esc(st.tax_number)}</div>` : ''}
    </div>
    <div class="r-meta">
      <div><span>Receipt</span><span>#${receiptNo(s.id)}</span></div>
      <div><span>Date</span><span>${fmtDate(s.created_at)}</span></div>
      <div><span>Served by</span><span>${esc(s.cashier)}</span></div>
    </div>
    ${s.status !== 'completed' ? `<div class="r-stamp">${s.status === 'refunded' ? 'REFUNDED' : 'PARTLY REFUNDED'}</div>` : ''}
    <table class="r-items">${s.items.map((i) => `<tr>
      <td>${i.qty} &times; ${esc(i.name)}<div class="muted">@ ${money(i.unit_price)}${i.tax_rate ? ` &middot; ${i.tax_rate}% ${label}` : ''}</div></td>
      <td class="num">${money(i.unit_price * i.qty)}</td></tr>`).join('')}
    </table>
    <div class="r-totals">
      <div><span>Subtotal</span><span>${money(s.subtotal)}</span></div>
      ${s.discount ? `<div><span>Discount (${s.discount_pct}%)</span><span>&minus;${money(s.discount)}</span></div>` : ''}
      <div><span>${label}${s.tax_inclusive ? ' included' : ''}</span><span>${money(s.tax)}</span></div>
      <div class="grand"><span>Total</span><span>${money(s.total)}</span></div>
      <div><span>Paid by ${s.payment_method}</span><span>${money(s.tendered)}</span></div>
      ${s.change_due ? `<div><span>Change</span><span>${money(s.change_due)}</span></div>` : ''}
    </div>
    ${s.card_last4 ? `<div class="r-card">
      <div><span>${esc((s.card_brand || 'Card').toUpperCase())} **** ${esc(s.card_last4)}</span><span>${READ_METHODS[s.card_read_method] || ''}</span></div>
      ${s.card_app_name ? `<div><span>Application</span><span>${esc(s.card_app_name)}</span></div>` : ''}
      ${s.card_aid ? `<div><span>AID</span><span>${esc(s.card_aid)}</span></div>` : ''}
      ${s.card_auth_code ? `<div><span>Auth code</span><span>${esc(s.card_auth_code)}</span></div>` : ''}
      <div class="r-small">Cardholder copy. Please keep.</div>
    </div>` : ''}
    ${(s.refunds || []).map((r) => `<div class="r-refund">
      <div class="r-refund-head"><span>REFUND ${fmtDate(r.created_at)}</span><span>&minus;${money(r.amount)}</span></div>
      ${r.items.map((i) => `<div><span>${i.qty} &times; ${esc(i.name)}</span><span>&minus;${money(i.amount)}</span></div>`).join('')}
      <div><span>To ${REFUND_METHODS[r.method]}</span><span>${esc(r.user_name || '')}</span></div>
    </div>`).join('')}
    ${st.receipt_footer ? `<div class="r-foot">${esc(st.receipt_footer)}</div>` : ''}
  </div>`;
}

function printReceipt(sale) {
  $('#print-area').innerHTML = receiptHtml(sale);
  window.print();
}

const READ_METHODS = {
  contactless_emv: 'Contactless', contact_emv: 'Chip', magnetic_stripe_track2: 'Swipe',
  magnetic_stripe_fallback: 'Swipe', contactless_magstripe_mode: 'Contactless',
};
const REFUND_METHODS = { cash: 'cash', card: 'card (manual)', stripe: 'original card' };

function showReceipt(sale, onChange) {
  const canRefund = isAdmin() && sale.status !== 'refunded';
  const m = openModal(`<div class="receipt-wrap">${receiptHtml(sale)}</div>
    ${sale.refunds?.length ? `<p class="muted small">${sale.refunds.map((r) => `Refund by ${esc(r.user_name)}: ${esc(r.reason)}${r.provider_ref ? ` (Stripe ${esc(r.provider_ref)}, ${esc(r.provider_status)})` : ''}`).join('<br>')}</p>` : ''}
    <div class="actions">
      ${canRefund ? '<button class="danger" id="refundBtn">Refund</button><span class="spacer"></span>' : ''}
      <button id="printBtn">Print</button>
      <button class="primary" data-close autofocus>Done</button>
    </div>`);
  $('#printBtn', m.el).addEventListener('click', () => printReceipt(sale));
  $('#refundBtn', m.el)?.addEventListener('click', () => refundModal(sale, (updated) => {
    m.close();
    onChange?.();
    showReceipt(updated, onChange);
  }));
}

// Same split as the server: the last unit of a line takes whatever is left.
function refundLineAmount(item, qty) {
  const remaining = item.qty - item.refunded_qty;
  if (!qty) return 0;
  return qty === remaining ? item.total - item.refunded_amount : Math.round((item.total * qty) / item.qty);
}

function refundModal(sale, onDone) {
  const items = sale.items.filter((i) => i.qty > i.refunded_qty);
  const methods = [];
  if (sale.stripe_payment_intent) methods.push(['stripe', "Back to the customer's card (via Stripe)"]);
  else if (sale.payment_method === 'card') methods.push(['card', 'Card, refunded on the separate card machine']);
  methods.push(['cash', 'Cash from the till']);
  const r = openModal(`<h2>Refund from sale #${receiptNo(sale.id)}</h2>
    <form id="refundForm">
      <div class="table-wrap"><table class="data compact">
        <thead><tr><th>Item</th><th class="num">Paid</th><th class="num">Can refund</th><th class="num">Refund qty</th></tr></thead>
        <tbody>${items.map((i) => `<tr>
          <td>${esc(i.name)}</td><td class="num">${money(i.total)}</td><td class="num">${i.qty - i.refunded_qty}</td>
          <td class="num"><input class="qty-in" type="number" min="0" max="${i.qty - i.refunded_qty}" step="1" value="${i.qty - i.refunded_qty}" data-item="${i.id}"></td>
        </tr>`).join('')}</tbody>
      </table></div>
      <p class="refund-total">Refund total: <strong id="refundTotal"></strong></p>
      <label>Refund to <select name="method">${methods.map(([v, l]) => `<option value="${v}">${esc(l)}</option>`).join('')}</select></label>
      <label class="check"><input type="checkbox" name="restock" checked> Put returned items back into stock</label>
      <label>Reason <input name="reason" required maxlength="200" placeholder="e.g. faulty, changed mind"></label>
      <div class="actions"><button type="button" data-close>Cancel</button><button class="danger" id="refundGo">Refund</button></div>
    </form>`, { wide: true });
  const inputs = $$('.qty-in', r.el);
  const chosen = () => inputs.map((inp) => {
    const item = items.find((i) => i.id === Number(inp.dataset.item));
    const qty = Math.min(Math.max(parseInt(inp.value, 10) || 0, 0), item.qty - item.refunded_qty);
    return { item, qty };
  }).filter((c) => c.qty > 0);
  const update = () => {
    const total = chosen().reduce((a, c) => a + refundLineAmount(c.item, c.qty), 0);
    $('#refundTotal', r.el).textContent = money(total);
    $('#refundGo', r.el).textContent = `Refund ${money(total)}`;
  };
  inputs.forEach((i) => i.addEventListener('input', update));
  update();
  onSubmit($('#refundForm', r.el), async (d) => {
    const lines = chosen();
    if (!lines.length) throw new Error('Set a refund quantity for at least one item');
    const updated = await api('POST', `/api/sales/${sale.id}/refunds`, {
      items: lines.map((c) => ({ sale_item_id: c.item.id, qty: c.qty })),
      method: d.method,
      restock: 'restock' in d,
      reason: d.reason,
    });
    r.close();
    toast(`Refund recorded for sale #${receiptNo(sale.id)}`, 'success');
    onDone(updated);
  });
}

// ---------- SALES HISTORY
async function renderSales(main) {
  main.innerHTML = `<h1>Sales</h1>${rangeBar()}
    <div class="toolbar"><input id="receiptSearch" type="search" placeholder="Find receipt number"></div>
    <div class="table-wrap"><table class="data">
      <thead><tr><th>Receipt</th><th>Time</th><th>Cashier</th><th class="num">Items</th><th class="num">Total</th><th>Payment</th><th>Status</th></tr></thead>
      <tbody id="salesBody"></tbody>
    </table></div>`;
  let rows = [];
  const draw = () => {
    const q = $('#receiptSearch').value.trim().replace(/^#?0*/, '');
    const list = q ? rows.filter((s) => String(s.id).includes(q)) : rows;
    $('#salesBody').innerHTML = list.length
      ? list.map((s) => `<tr class="click" data-id="${s.id}">
          <td>#${receiptNo(s.id)}</td><td>${fmtDate(s.created_at)}</td><td>${esc(s.cashier)}</td>
          <td class="num">${s.item_count}</td><td class="num">${money(s.total)}${s.refunded_amount ? `<div class="muted small">&minus;${money(s.refunded_amount)} refunded</div>` : ''}</td>
          <td>${s.payment_method}${s.card_last4 ? ` <span class="muted">${esc(s.card_brand || '')} ${esc(s.card_last4)}</span>` : ''}</td>
          <td><span class="badge ${s.status}">${s.status.replace('_', ' ')}</span></td></tr>`).join('')
      : '<tr><td colspan="7" class="empty">No sales in this period</td></tr>';
  };
  const getRange = wireRange(main, () => load());
  const load = async () => { rows = await api('GET', `/api/sales?${getRange().query}`); draw(); };
  $('#receiptSearch').addEventListener('input', draw);
  $('#salesBody').addEventListener('click', async (e) => {
    const tr = e.target.closest('tr[data-id]');
    if (!tr) return;
    try { showReceipt(await api('GET', `/api/sales/${tr.dataset.id}`), load); } catch (err) { toast(err.message, 'error'); }
  });
  await load();
}

// ---------- PRODUCTS
async function renderProducts(main) {
  const admin = isAdmin();
  main.innerHTML = `<h1>Products</h1>
    <div class="toolbar">
      <input id="pSearch" type="search" placeholder="Search name, SKU or barcode">
      <label class="check"><input type="checkbox" id="pInactive"> Show inactive</label>
      <span class="spacer"></span>
      ${admin ? '<button id="catBtn">Categories</button><button class="primary" id="addBtn">Add product</button>' : ''}
    </div>
    <div class="table-wrap"><table class="data">
      <thead><tr><th>SKU</th><th>Name</th><th>Category</th><th class="num">Price</th><th class="num">${esc(state.settings.tax_label)} %</th><th class="num">Stock</th><th></th></tr></thead>
      <tbody id="pBody"></tbody>
    </table></div>`;
  let list = [];
  const load = async () => {
    [list, state.categories] = await Promise.all([api('GET', '/api/products?all=1'), api('GET', '/api/categories')]);
    draw();
  };
  const draw = () => {
    const q = $('#pSearch').value.trim().toLowerCase();
    const showInactive = $('#pInactive').checked;
    const rows = list.filter((p) => (showInactive || p.active) &&
      (!q || p.name.toLowerCase().includes(q) || p.sku.toLowerCase().includes(q) || (p.barcode || '').includes(q)));
    $('#pBody').innerHTML = rows.length
      ? rows.map((p) => `<tr class="${p.active ? '' : 'inactive'}">
          <td>${esc(p.sku)}</td>
          <td>${esc(p.name)}${p.active ? '' : ' <span class="badge">inactive</span>'}</td>
          <td>${esc(p.category || '')}</td>
          <td class="num">${money(p.price)}</td>
          <td class="num">${p.tax_rate}</td>
          <td class="num ${p.track_stock && p.stock <= p.low_stock ? 'warn' : ''}">${p.track_stock ? p.stock : '&ndash;'}</td>
          <td class="row-actions">${admin ? `<button data-edit="${p.id}">Edit</button>${p.track_stock ? `<button data-stock="${p.id}">Stock</button>` : ''}` : ''}</td>
        </tr>`).join('')
      : '<tr><td colspan="7" class="empty">No products</td></tr>';
  };
  $('#pSearch').addEventListener('input', draw);
  $('#pInactive').addEventListener('change', draw);
  if (admin) {
    $('#addBtn').addEventListener('click', () => productModal(null, load));
    $('#catBtn').addEventListener('click', () => categoriesModal(load));
    $('#pBody').addEventListener('click', (e) => {
      const edit = e.target.closest('[data-edit]');
      const stock = e.target.closest('[data-stock]');
      if (edit) productModal(list.find((p) => p.id === Number(edit.dataset.edit)), load);
      if (stock) stockModal(list.find((p) => p.id === Number(stock.dataset.stock)), load);
    });
  }
  await load();
}

function productModal(p, onSaved) {
  const isNew = !p;
  const v = p || { sku: '', barcode: '', name: '', category_id: '', price: 0, cost: 0, tax_rate: Number(state.settings.default_tax_rate), track_stock: 1, low_stock: 5, active: 1 };
  const step = 1 / 10 ** digits;
  const m = openModal(`<h2>${isNew ? 'Add product' : `Edit ${esc(p.name)}`}</h2>
    <form id="productForm" class="grid-form">
      <label class="span2">Name <input name="name" value="${esc(v.name)}" required maxlength="120" autofocus></label>
      <label>SKU <input name="sku" value="${esc(v.sku)}" required maxlength="64"></label>
      <label>Barcode <input name="barcode" value="${esc(v.barcode || '')}" maxlength="64"></label>
      <label>Category <select name="category_id"><option value="">None</option>
        ${state.categories.map((c) => `<option value="${c.id}" ${c.id === v.category_id ? 'selected' : ''}>${esc(c.name)}</option>`).join('')}
      </select></label>
      <label>${esc(state.settings.tax_label)} rate % <input name="tax_rate" type="number" min="0" max="100" step="0.01" value="${v.tax_rate}" required></label>
      <label>Selling price${taxInclusive() ? ` (incl. ${esc(state.settings.tax_label)})` : ''} <input name="price" type="number" min="0" step="${step}" value="${toMajor(v.price)}" required></label>
      <label>Unit cost (ex. ${esc(state.settings.tax_label)}) <input name="cost" type="number" min="0" step="${step}" value="${toMajor(v.cost)}"></label>
      <label class="check span2"><input type="checkbox" name="track_stock" ${v.track_stock ? 'checked' : ''}> Track stock for this product</label>
      ${isNew ? '<label>Opening stock <input name="stock" type="number" min="0" step="1" value="0"></label>' : ''}
      <label>Low stock warning at <input name="low_stock" type="number" min="0" step="1" value="${v.low_stock}"></label>
      ${isNew ? '' : `<label class="check span2"><input type="checkbox" name="active" ${v.active ? 'checked' : ''}> Active (shown on the sell screen)</label>`}
      <div class="actions span2"><button type="button" data-close>Cancel</button><button class="primary">${isNew ? 'Add product' : 'Save changes'}</button></div>
    </form>`, { wide: true });
  onSubmit($('#productForm', m.el), async (d) => {
    const body = {
      ...d,
      price: toMinor(d.price),
      cost: toMinor(d.cost || 0),
      track_stock: 'track_stock' in d,
      active: isNew ? true : 'active' in d,
    };
    await api(isNew ? 'POST' : 'PUT', isNew ? '/api/products' : `/api/products/${p.id}`, body);
    m.close();
    toast(isNew ? 'Product added' : 'Product saved', 'success');
    onSaved();
  });
}

function stockModal(p, onSaved) {
  const m = openModal(`<h2>Adjust stock: ${esc(p.name)}</h2>
    <p>Current stock: <strong>${p.stock}</strong></p>
    <form id="stockForm">
      <label>Change (use a minus sign to remove stock) <input name="change" type="number" step="1" required autofocus></label>
      <label>Reason <select name="reason">
        <option value="delivery">Delivery received</option>
        <option value="count">Stock count correction</option>
        <option value="damaged">Damaged or expired</option>
        <option value="return">Customer return (no refund)</option>
        <option value="other">Other</option>
      </select></label>
      <label>Note <input name="note" maxlength="200" placeholder="e.g. delivery note number"></label>
      <div class="actions"><button type="button" id="historyBtn">History</button><span class="spacer"></span><button type="button" data-close>Cancel</button><button class="primary">Save</button></div>
    </form>`);
  $('#historyBtn', m.el).addEventListener('click', async () => {
    try {
      const rows = await api('GET', `/api/products/${p.id}/movements`);
      openModal(`<h2>Stock history: ${esc(p.name)}</h2>
        <div class="table-wrap"><table class="data"><thead><tr><th>When</th><th>Change</th><th>Reason</th><th>By</th><th>Note</th></tr></thead><tbody>
        ${rows.map((r) => `<tr><td>${fmtDate(r.created_at)}</td><td class="num">${r.change > 0 ? '+' : ''}${r.change}</td>
          <td>${esc(r.reason)}${r.sale_id ? ` #${receiptNo(r.sale_id)}` : ''}</td><td>${esc(r.user_name || '')}</td><td>${esc(r.note || '')}</td></tr>`).join('')
          || '<tr><td colspan="5" class="empty">No movements</td></tr>'}
        </tbody></table></div><div class="actions"><button class="primary" data-close>Close</button></div>`, { wide: true });
    } catch (err) { toast(err.message, 'error'); }
  });
  onSubmit($('#stockForm', m.el), async (d) => {
    const updated = await api('POST', `/api/products/${p.id}/stock`, { ...d, change: Number(d.change) });
    m.close();
    toast(`Stock for ${p.name} is now ${updated.stock}`, 'success');
    onSaved();
  });
}

function categoriesModal(onChange) {
  const m = openModal(`<h2>Categories</h2>
    <ul class="list" id="catList"></ul>
    <form id="catForm" class="inline-form">
      <input name="name" placeholder="New category name" required maxlength="50" autofocus>
      <button class="primary">Add</button>
    </form>
    <div class="actions"><button data-close>Close</button></div>`);
  const draw = () => {
    $('#catList', m.el).innerHTML = state.categories.map((c) =>
      `<li><span>${esc(c.name)}</span><button class="ghost danger-text" data-del="${c.id}">Delete</button></li>`).join('')
      || '<li class="empty">No categories yet</li>';
  };
  const refresh = async () => { state.categories = await api('GET', '/api/categories'); draw(); onChange(); };
  $('#catList', m.el).addEventListener('click', async (e) => {
    const b = e.target.closest('[data-del]');
    if (!b) return;
    const cat = state.categories.find((c) => c.id === Number(b.dataset.del));
    if (!(await confirmModal(`Delete ${cat.name}?`, 'Products in this category are kept but will have no category.', { confirmLabel: 'Delete', danger: true }))) return;
    try { await api('DELETE', `/api/categories/${cat.id}`); await refresh(); } catch (err) { toast(err.message, 'error'); }
  });
  onSubmit($('#catForm', m.el), async (d) => {
    await api('POST', '/api/categories', d);
    $('#catForm', m.el).reset();
    await refresh();
  });
  draw();
}

// ---------- REPORTS
async function renderReports(main) {
  main.innerHTML = `<h1>Reports</h1>${rangeBar()}
    <div class="toolbar"><span class="spacer"></span><button id="csvBtn">Export sales (CSV)</button><button id="printReport">Print report</button></div>
    <div id="report"></div>`;
  const getRange = wireRange(main, () => load());
  const label = esc(state.settings.tax_label);
  const load = async () => {
    const r = await api('GET', `/api/reports/summary?${getRange().query}`);
    const avg = r.sales.count ? Math.round(r.sales.total / r.sales.count) : 0;
    const marginPct = r.margin.revenue ? ((r.margin.profit / r.margin.revenue) * 100).toFixed(1) : '0.0';
    $('#report').innerHTML = `
      <div class="cards">
        <div class="stat"><span>Net takings</span><strong>${money(r.net.total)}</strong></div>
        <div class="stat"><span>Sales</span><strong>${r.sales.count}</strong><small>${money(r.sales.total)} gross</small></div>
        <div class="stat"><span>Average sale</span><strong>${money(avg)}</strong></div>
        <div class="stat"><span>Refunds</span><strong>${money(r.refunds.total)}</strong><small>${r.refunds.count} refunded</small></div>
        <div class="stat"><span>${label} (net)</span><strong>${money(r.net.tax)}</strong></div>
        <div class="stat"><span>Discounts given</span><strong>${money(r.sales.discount)}</strong></div>
        <div class="stat"><span>Gross profit</span><strong>${money(r.margin.profit)}</strong><small>${marginPct}% margin, ex. ${label}</small></div>
      </div>
      <div class="report-grid">
        <section class="panel"><h2>Payments</h2>
          <table class="data"><thead><tr><th>Method</th><th class="num">Sales</th><th class="num">Refunds</th><th class="num">Net</th></tr></thead><tbody>
          ${r.methods.map((m) => `<tr><td>${m.method === 'cash' ? 'Cash' : 'Card'}</td><td class="num">${money(m.sales)}</td>
            <td class="num">${money(m.refunds)}</td><td class="num"><strong>${money(m.net)}</strong></td></tr>`).join('')}
          </tbody></table>
        </section>
        <section class="panel"><h2>By cashier</h2>
          <table class="data"><thead><tr><th>Cashier</th><th class="num">Sales</th><th class="num">Total</th></tr></thead><tbody>
          ${r.byCashier.map((c) => `<tr><td>${esc(c.name)}</td><td class="num">${c.count}</td><td class="num">${money(c.total)}</td></tr>`).join('')
            || '<tr><td colspan="3" class="empty">No sales</td></tr>'}
          </tbody></table>
        </section>
        <section class="panel"><h2>Top products</h2>
          <table class="data"><thead><tr><th>Product</th><th class="num">Qty</th><th class="num">Takings</th></tr></thead><tbody>
          ${r.topProducts.map((p) => `<tr><td>${esc(p.name)} <span class="muted">${esc(p.sku)}</span></td><td class="num">${p.qty}</td><td class="num">${money(p.total)}</td></tr>`).join('')
            || '<tr><td colspan="3" class="empty">No sales</td></tr>'}
          </tbody></table>
        </section>
        <section class="panel"><h2>Low stock (now)</h2>
          <table class="data"><thead><tr><th>Product</th><th class="num">Stock</th><th class="num">Warn at</th></tr></thead><tbody>
          ${r.lowStock.map((p) => `<tr><td>${esc(p.name)} <span class="muted">${esc(p.sku)}</span></td><td class="num warn">${p.stock}</td><td class="num">${p.low_stock}</td></tr>`).join('')
            || '<tr><td colspan="3" class="empty">All stock above warning levels</td></tr>'}
          </tbody></table>
        </section>
      </div>`;
  };
  $('#csvBtn').addEventListener('click', async () => {
    const { query, from, to } = getRange();
    try {
      const res = await fetch(`/api/reports/sales.csv?${query}`, { headers: { Authorization: `Bearer ${state.token}` } });
      if (!res.ok) throw new Error((await res.json()).error);
      const url = URL.createObjectURL(await res.blob());
      const a = Object.assign(document.createElement('a'), { href: url, download: `sales_${from}_to_${to}.csv` });
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (err) { toast(err.message, 'error'); }
  });
  $('#printReport').addEventListener('click', () => {
    const { from, to } = getRange();
    $('#print-area').innerHTML = `<div class="print-report"><h1>${esc(state.settings.store_name)}: report ${from} to ${to}</h1>
      <p>Printed ${fmtDate(new Date().toISOString())} by ${esc(state.user.name)}</p>${$('#report').innerHTML}</div>`;
    window.print();
  });
  await load();
}

// ---------- TILL (cash drawer sessions)
const DENOMINATIONS = {
  GBP: [5000, 2000, 1000, 500, 200, 100, 50, 20, 10, 5, 2, 1],
  EUR: [50000, 20000, 10000, 5000, 2000, 1000, 500, 200, 100, 50, 20, 10, 5, 2, 1],
};

function shiftReportHtml(s) {
  const row = (label, value, cls = '') => `<div class="${cls}"><span>${label}</span><span>${value}</span></div>`;
  const hasVariance = s.variance !== null && s.variance !== undefined;
  return `<div class="receipt shift-report">
    <div class="r-head"><strong>${esc(state.settings.store_name)}</strong><div>${s.status === 'closed' ? 'Z report: till closed' : 'X report: till open'}</div></div>
    <div class="r-meta">
      ${row('Session', `#${s.id}`)}
      ${row('Opened', `${fmtDate(s.opened_at)}, ${esc(s.opened_by_name)}`)}
      ${s.closed_at ? row('Closed', `${fmtDate(s.closed_at)}, ${esc(s.closed_by_name)}`) : ''}
    </div>
    <div class="r-totals">
      ${row(`Card sales (${s.card_sales.count})`, money(s.card_sales.total))}
      ${row(`Card refunds (${s.card_refunds.count})`, `&minus;${money(s.card_refunds.total)}`)}
      ${row(`Cash sales (${s.cash_sales.count})`, money(s.cash_sales.total))}
      ${row(`Cash refunds (${s.cash_refunds.count})`, `&minus;${money(s.cash_refunds.total)}`)}
    </div>
    <div class="r-totals">
      ${row('Opening float', money(s.opening_float))}
      ${row('Cash sales less refunds', money(s.cash_sales.total - s.cash_refunds.total))}
      ${row('Paid in', money(s.paid_in))}
      ${row('Paid out', `&minus;${money(s.paid_out)}`)}
      ${s.expected_cash === null ? row('Expected in drawer', 'shown after counting') : row('Expected in drawer', money(s.expected_cash), 'grand')}
      ${s.counted_cash !== null && s.counted_cash !== undefined ? row('Counted', money(s.counted_cash)) : ''}
      ${hasVariance ? row(s.variance === 0 ? 'Balanced' : s.variance > 0 ? 'Over' : 'Short', money(Math.abs(s.variance)), `grand${s.variance ? ' variance' : ''}`) : ''}
    </div>
    ${s.movements.length ? `<div class="r-totals">${s.movements.map((m) => row(
      `${m.type === 'paid_in' ? 'In' : 'Out'}: ${esc(m.reason)} (${esc(m.user_name)})`,
      `${m.type === 'paid_in' ? '' : '&minus;'}${money(m.amount)}`)).join('')}</div>` : ''}
    ${s.notes ? `<div class="r-foot">${esc(s.notes)}</div>` : ''}
  </div>`;
}

function printShift(s) {
  $('#print-area').innerHTML = shiftReportHtml(s);
  window.print();
}

async function renderTill(main) {
  main.innerHTML = `<h1>Till</h1><div id="current"></div>
    ${isAdmin() ? `<h2 class="section-gap">Past till sessions</h2>${rangeBar()}
      <div class="table-wrap"><table class="data">
        <thead><tr><th>#</th><th>Opened</th><th>Closed</th><th class="num">Card</th><th class="num">Cash</th><th class="num">Expected</th><th class="num">Counted</th><th class="num">Over / short</th></tr></thead>
        <tbody id="shiftBody"></tbody>
      </table></div>` : ''}`;

  let history = [];
  let getRange = null;

  const loadHistory = async () => {
    if (!isAdmin()) return;
    history = await api('GET', `/api/shifts?${getRange().query}`);
    $('#shiftBody').innerHTML = history.map((s) => `<tr class="click" data-id="${s.id}">
      <td>${s.id}</td><td>${fmtDate(s.opened_at)}<div class="muted small">${esc(s.opened_by_name)}</div></td>
      <td>${s.closed_at ? `${fmtDate(s.closed_at)}<div class="muted small">${esc(s.closed_by_name)}</div>` : '<span class="badge completed">open</span>'}</td>
      <td class="num">${money(s.card_sales.total - s.card_refunds.total)}</td>
      <td class="num">${money(s.cash_sales.total - s.cash_refunds.total)}</td>
      <td class="num">${money(s.expected_cash)}</td>
      <td class="num">${s.counted_cash === null ? '' : money(s.counted_cash)}</td>
      <td class="num ${s.variance ? 'warn' : ''}">${s.variance === null ? '' : (s.variance > 0 ? '+' : s.variance < 0 ? '&minus;' : '') + money(Math.abs(s.variance))}</td>
    </tr>`).join('') || '<tr><td colspan="8" class="empty">No till sessions in this period</td></tr>';
  };

  const drawCurrent = async () => {
    const { shift } = await api('GET', '/api/shifts/current');
    state.shift = shift;
    const box = $('#current');
    if (!shift) {
      box.innerHTML = '<div class="panel"><p>The till is closed.</p><button class="primary" id="openTillBtn">Open till</button></div>';
      $('#openTillBtn').addEventListener('click', () => openTillModal(async () => { await drawCurrent(); await loadHistory(); }));
      return;
    }
    box.innerHTML = `<div class="till-current">
      <div class="receipt-wrap">${shiftReportHtml(shift)}</div>
      <div class="till-actions">
        <button id="paidIn">Pay cash in</button>
        <button id="paidOut">Pay cash out</button>
        <button id="xReport">Print X report</button>
        <button class="primary" id="closeTill">Count and close till</button>
      </div>
    </div>`;
    $('#paidIn').addEventListener('click', () => cashMoveModal('paid_in', drawCurrent));
    $('#paidOut').addEventListener('click', () => cashMoveModal('paid_out', drawCurrent));
    $('#xReport').addEventListener('click', () => printShift(shift));
    $('#closeTill').addEventListener('click', () => closeTillModal(async () => { await drawCurrent(); await loadHistory(); }));
  };

  if (isAdmin()) {
    getRange = wireRange(main, loadHistory);
    $('#shiftBody').addEventListener('click', (e) => {
      const tr = e.target.closest('tr[data-id]');
      const s = tr && history.find((h) => h.id === Number(tr.dataset.id));
      if (!s) return;
      const m = openModal(`<div class="receipt-wrap">${shiftReportHtml(s)}</div>
        <div class="actions"><button id="printShift">Print</button><button class="primary" data-close>Close</button></div>`);
      $('#printShift', m.el).addEventListener('click', () => printShift(s));
    });
  }
  await Promise.all([drawCurrent(), loadHistory()]);
}

function cashMoveModal(type, onDone) {
  const isIn = type === 'paid_in';
  const m = openModal(`<h2>${isIn ? 'Pay cash into the till' : 'Pay cash out of the till'}</h2>
    <form id="moveForm">
      <label>Amount <input name="amount" type="number" min="0" step="${1 / 10 ** digits}" required autofocus></label>
      <label>Reason <input name="reason" required maxlength="200" placeholder="${isIn ? 'e.g. extra change from the bank' : 'e.g. milk for the staff room, receipt kept'}"></label>
      <div class="actions"><button type="button" data-close>Cancel</button><button class="primary">Save</button></div>
    </form>`);
  onSubmit($('#moveForm', m.el), async (d) => {
    await api('POST', '/api/shifts/current/movements', { type, amount: toMinor(d.amount), reason: d.reason });
    m.close();
    toast('Saved', 'success');
    onDone();
  });
}

function closeTillModal(onDone) {
  const denoms = digits === 2 ? DENOMINATIONS[state.settings.currency] : null;
  const m = openModal(`<h2>Count and close the till</h2>
    <p class="muted">Count all the cash in the drawer, including the float.</p>
    <form id="closeForm">
      ${denoms ? `<div class="denoms">${denoms.map((d) => `<label>${money(d)} <input type="number" min="0" step="1" data-denom="${d}" placeholder="0"></label>`).join('')}</div>` : ''}
      <label>Total counted <input name="counted" type="number" min="0" step="${1 / 10 ** digits}" required ${denoms ? '' : 'autofocus'}></label>
      <label>Notes <input name="notes" maxlength="500" placeholder="Optional"></label>
      <div class="actions"><button type="button" data-close>Cancel</button><button class="primary">Close till</button></div>
    </form>`, { wide: true });
  const counted = $('[name=counted]', m.el);
  $$('[data-denom]', m.el).forEach((inp) => inp.addEventListener('input', () => {
    const total = $$('[data-denom]', m.el).reduce((a, i) => a + Number(i.dataset.denom) * (parseInt(i.value, 10) || 0), 0);
    counted.value = toMajor(total);
  }));
  onSubmit($('#closeForm', m.el), async (d) => {
    const result = await api('POST', '/api/shifts/current/close', { counted_cash: toMinor(d.counted), notes: d.notes });
    m.close();
    const r = openModal(`<div class="receipt-wrap">${shiftReportHtml(result)}</div>
      <div class="actions"><button id="printZ">Print Z report</button><button class="primary" data-close>Done</button></div>`);
    $('#printZ', r.el).addEventListener('click', () => printShift(result));
    onDone();
  });
}

// ---------- STAFF
async function renderUsers(main) {
  main.innerHTML = `<h1>Staff</h1>
    <div class="toolbar"><span class="spacer"></span><button class="primary" id="addUser">Add staff member</button></div>
    <div class="table-wrap"><table class="data">
      <thead><tr><th>Name</th><th>Username</th><th>Role</th><th>Status</th><th>Added</th><th></th></tr></thead>
      <tbody id="uBody"></tbody>
    </table></div>`;
  let users = [];
  const load = async () => {
    users = await api('GET', '/api/users');
    $('#uBody').innerHTML = users.map((u) => `<tr class="${u.active ? '' : 'inactive'}">
      <td>${esc(u.name)}</td><td>${esc(u.username)}</td><td>${u.role === 'admin' ? 'Manager' : 'Cashier'}</td>
      <td>${u.active ? 'Active' : '<span class="badge">disabled</span>'}</td><td>${fmtDate(u.created_at)}</td>
      <td class="row-actions"><button data-edit="${u.id}">Edit</button></td></tr>`).join('');
  };
  $('#addUser').addEventListener('click', () => userModal(null, load));
  $('#uBody').addEventListener('click', (e) => {
    const b = e.target.closest('[data-edit]');
    if (b) userModal(users.find((u) => u.id === Number(b.dataset.edit)), load);
  });
  await load();
}

function userModal(u, onSaved) {
  const isNew = !u;
  const m = openModal(`<h2>${isNew ? 'Add staff member' : `Edit ${esc(u.name)}`}</h2>
    <form id="userForm">
      <label>Full name <input name="name" value="${esc(u?.name || '')}" required maxlength="100" autofocus></label>
      ${isNew ? '<label>Username <input name="username" required maxlength="50" pattern="[A-Za-z0-9._\\-]+" autocapitalize="none"></label>' : ''}
      <label>Role <select name="role">
        <option value="cashier" ${u?.role === 'cashier' ? 'selected' : ''}>Cashier: sell, view sales and products</option>
        <option value="admin" ${u?.role === 'admin' ? 'selected' : ''}>Manager: everything, incl. refunds, stock and reports</option>
      </select></label>
      <label>${isNew ? 'PIN (4 to 8 digits)' : 'New PIN (leave blank to keep the current PIN)'}
        <input name="pin" type="password" inputmode="numeric" pattern="\\d{4,8}" ${isNew ? 'required' : ''}></label>
      ${isNew ? '' : `<label class="check"><input type="checkbox" name="active" ${u.active ? 'checked' : ''}> Account active</label>`}
      <div class="actions"><button type="button" data-close>Cancel</button><button class="primary">${isNew ? 'Add' : 'Save'}</button></div>
    </form>`);
  onSubmit($('#userForm', m.el), async (d) => {
    if (isNew) await api('POST', '/api/users', d);
    else await api('PUT', `/api/users/${u.id}`, { ...d, active: 'active' in d });
    m.close();
    toast('Staff member saved', 'success');
    onSaved();
  });
}

// ---------- SETTINGS
async function renderSettings(main) {
  const s = await api('GET', '/api/settings');
  main.innerHTML = `<h1>Settings</h1>
    <form id="settingsForm" class="panel grid-form settings">
      <h2 class="span2">Store</h2>
      <label class="span2">Store name <input name="store_name" value="${esc(s.store_name)}" required maxlength="100"></label>
      <label class="span2">Address (printed on receipts) <textarea name="store_address" rows="3" maxlength="300">${esc(s.store_address)}</textarea></label>
      <label>Tax registration number <input name="tax_number" value="${esc(s.tax_number)}" maxlength="50"></label>
      <label>Receipt footer <input name="receipt_footer" value="${esc(s.receipt_footer)}" maxlength="300"></label>
      <h2 class="span2">Money and tax</h2>
      <label>Currency (ISO code) <input name="currency" value="${esc(s.currency)}" required maxlength="3" pattern="[A-Za-z]{3}"></label>
      <label>Locale (number and date format) <input name="locale" value="${esc(s.locale)}" required maxlength="20"></label>
      <label>Tax name <input name="tax_label" value="${esc(s.tax_label)}" required maxlength="20"></label>
      <label>Default tax rate for new products % <input name="default_tax_rate" type="number" min="0" max="100" step="0.01" value="${esc(s.default_tax_rate)}" required></label>
      <label class="check span2"><input type="checkbox" name="tax_inclusive" ${s.tax_inclusive === '1' ? 'checked' : ''}> Prices include tax (normal for UK and EU retail)</label>
      <h2 class="span2">Controls</h2>
      <label>Maximum discount a cashier can give % <input name="max_cashier_discount" type="number" min="0" max="100" step="0.5" value="${esc(s.max_cashier_discount)}" required></label>
      <label class="check"><input type="checkbox" name="allow_negative_stock" ${s.allow_negative_stock === '1' ? 'checked' : ''}> Allow sales when stock is zero</label>
      <h2 class="span2">Card payments</h2>
      <label class="span2">How card payments are taken <select name="card_mode">
        <option value="manual" ${s.card_mode === 'manual' ? 'selected' : ''}>Separate card machine: staff confirm each payment by hand</option>
        <option value="stripe" ${s.card_mode === 'stripe' ? 'selected' : ''}>Stripe Terminal reader linked to this POS</option>
      </select></label>
      <div class="actions span2"><button class="primary">Save settings</button></div>
    </form>
    <section class="panel settings" id="terminalSetup"></section>`;
  renderTerminalSetup(s);
  onSubmit($('#settingsForm'), async (d) => {
    state.settings = await api('PUT', '/api/settings', {
      ...d,
      tax_inclusive: 'tax_inclusive' in d,
      allow_negative_stock: 'allow_negative_stock' in d,
    });
    setupFormats();
    renderShell();
    await go('settings');
    toast('Settings saved', 'success');
  });
}

async function renderTerminalSetup(settings) {
  const box = $('#terminalSetup');
  box.innerHTML = '<h2>Stripe Terminal</h2><p class="loading">Checking Stripe…</p>';
  let t;
  try {
    t = await api('GET', '/api/terminal/setup');
  } catch (err) {
    box.innerHTML = `<h2>Stripe Terminal</h2><p class="notice error">${esc(err.message)}</p>`;
    return;
  }
  if (!t.configured) {
    box.innerHTML = `<h2>Stripe Terminal</h2>
      <p class="notice">Stripe is not connected. Put your Stripe secret key in a file called <code>.env</code> in the POS folder,
      as <code>STRIPE_SECRET_KEY=sk_test_...</code>, then restart the POS. Start with a test key (sk_test_): it works with a
      simulated reader, so you can try everything without hardware or real money.</p>`;
    return;
  }
  const thisTill = local.get('pos_reader');
  const locName = (id) => t.locations.find((l) => l.id === id)?.display_name || id || '';
  box.innerHTML = `<h2>Stripe Terminal <span class="badge ${t.testMode ? 'test' : 'live'}">${t.testMode ? 'Test mode' : 'Live'}</span></h2>
    ${settings.card_mode !== 'stripe' ? '<p class="notice">The POS will not use these readers until you choose "Stripe Terminal reader" under Card payments above and save.</p>' : ''}
    <h3>Card readers</h3>
    <div class="table-wrap"><table class="data compact">
      <thead><tr><th>Name</th><th>Type</th><th>Location</th><th>Status</th><th>Default</th><th>This till</th><th></th></tr></thead>
      <tbody>${t.readers.map((r) => `<tr>
        <td>${esc(r.label)}<div class="muted small">${esc(r.serial_number || r.id)}</div></td>
        <td>${esc(r.device_type)}</td><td>${esc(locName(r.location))}</td>
        <td><span class="badge ${r.status === 'online' ? 'completed' : ''}">${esc(r.status || 'unknown')}</span></td>
        <td><input type="radio" name="defaultReader" value="${esc(r.id)}" ${settings.stripe_reader_id === r.id ? 'checked' : ''} aria-label="Default reader"></td>
        <td><input type="radio" name="tillReader" value="${esc(r.id)}" ${thisTill === r.id ? 'checked' : ''} aria-label="Use on this till"></td>
        <td class="row-actions"><button class="ghost danger-text" data-remove="${esc(r.id)}">Remove</button></td>
      </tr>`).join('') || '<tr><td colspan="7" class="empty">No readers yet</td></tr>'}</tbody>
    </table></div>
    <p class="muted small">"Default" is used by every till. "This till" overrides it on this device only, for shops with one reader per till.</p>
    ${t.locations.length ? `<h3>Add a reader</h3>
      <form id="readerForm" class="grid-form">
        <label>Registration code <input name="registration_code" required placeholder="${t.testMode ? 'simulated-wpe' : 'shown on the reader'}"></label>
        <label>Reader name <input name="label" required maxlength="100" placeholder="e.g. Till 1"></label>
        <label class="span2">Location <select name="location">${t.locations.map((l) => `<option value="${esc(l.id)}">${esc(l.display_name)}</option>`).join('')}</select></label>
        <p class="muted small span2">${t.testMode
          ? 'Test mode: enter <code>simulated-wpe</code> to add a simulated reader.'
          : 'On the reader, open its settings, choose "Generate pairing code" and enter the code it shows.'}</p>
        <div class="actions span2"><button class="primary">Add reader</button></div>
      </form>` : ''}
    <h3>Locations</h3>
    <ul class="list">${t.locations.map((l) => `<li><span>${esc(l.display_name)} <span class="muted small">${esc([l.address?.line1, l.address?.city, l.address?.postal_code].filter(Boolean).join(', '))}</span></span></li>`).join('')
      || '<li class="empty">Add a location before adding readers. Stripe needs the shop address.</li>'}</ul>
    <form id="locationForm" class="grid-form">
      <label class="span2">Location name <input name="display_name" required maxlength="100" value="${t.locations.length ? '' : esc(settings.store_name)}"></label>
      <label class="span2">Address line 1 <input name="line1" required maxlength="200"></label>
      <label>Town or city <input name="city" required maxlength="100"></label>
      <label>Postcode <input name="postal_code" required maxlength="20"></label>
      <label>Country (2-letter code) <input name="country" required maxlength="2" value="GB"></label>
      <div class="actions span2"><button>Add location</button></div>
    </form>`;

  $$('[name=defaultReader]', box).forEach((r) => r.addEventListener('change', async () => {
    try {
      state.settings = await api('PUT', '/api/settings', { stripe_reader_id: r.value });
      toast('Default reader saved', 'success');
    } catch (err) { toast(err.message, 'error'); }
  }));
  $$('[name=tillReader]', box).forEach((r) => r.addEventListener('change', () => {
    local.set('pos_reader', r.value);
    toast('This till will use that reader', 'success');
  }));
  $$('[data-remove]', box).forEach((b) => b.addEventListener('click', async () => {
    if (!(await confirmModal('Remove this reader?', 'It will be unlinked from your Stripe account and must be registered again before it can be used.', { confirmLabel: 'Remove', danger: true }))) return;
    try {
      await api('DELETE', `/api/terminal/readers/${encodeURIComponent(b.dataset.remove)}`);
      renderTerminalSetup(state.settings);
    } catch (err) { toast(err.message, 'error'); }
  }));
  const readerForm = $('#readerForm', box);
  if (readerForm) {
    onSubmit(readerForm, async (d) => {
      const reader = await api('POST', '/api/terminal/readers', d);
      if (!state.settings.stripe_reader_id) state.settings = await api('PUT', '/api/settings', { stripe_reader_id: reader.id });
      toast(`Reader ${reader.label} added`, 'success');
      renderTerminalSetup(state.settings);
    });
  }
  onSubmit($('#locationForm', box), async (d) => {
    await api('POST', '/api/terminal/locations', d);
    toast('Location added', 'success');
    renderTerminalSetup(state.settings);
  });
}

// ---------- SYSTEM (managers): health, backups, sessions and security, data tools
const SYSTEM_TABS = [['health', 'Health'], ['backups', 'Backups'], ['security', 'Sessions and security'], ['data', 'Data tools']];
let systemTab = 'health';

function fmtBytes(n) {
  if (n === null || n === undefined) return '';
  const units = ['B', 'kB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return `${n.toFixed(i && n < 10 ? 1 : 0)} ${units[i]}`;
}

function fmtDuration(seconds) {
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return d ? `${d} d ${h} h` : h ? `${h} h ${m} min` : `${m} min`;
}

function deviceName(ua = '') {
  const os = /iPad/.test(ua) ? 'iPad' : /iPhone/.test(ua) ? 'iPhone' : /Android/.test(ua) ? 'Android'
    : /Windows/.test(ua) ? 'Windows' : /Mac OS X/.test(ua) ? 'Mac' : /Linux/.test(ua) ? 'Linux' : 'Unknown device';
  const browser = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox'
    : /Safari\//.test(ua) ? 'Safari' : /node|undici/i.test(ua) ? 'Script' : '';
  return browser ? `${browser} on ${os}` : os;
}

async function download(url, fallbackName) {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${state.token}` } });
  if (!res.ok) {
    let message = '';
    try { message = (await res.json()).error; } catch { /* not JSON */ }
    throw new Error(message || `Download failed (${res.status})`);
  }
  const name = /filename="([^"]+)"/.exec(res.headers.get('content-disposition') || '')?.[1] || fallbackName;
  const href = URL.createObjectURL(await res.blob());
  Object.assign(document.createElement('a'), { href, download: name }).click();
  setTimeout(() => URL.revokeObjectURL(href), 1000);
}

async function renderSystem(main) {
  main.innerHTML = `<h1>System</h1>
    <div class="tabs" role="tablist">${SYSTEM_TABS.map(([id, label]) =>
      `<button role="tab" data-tab="${id}" aria-selected="${id === systemTab}">${label}</button>`).join('')}</div>
    <div id="sysBody"></div>`;
  const draw = async () => {
    $$('[data-tab]', main).forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === systemTab)));
    const box = $('#sysBody');
    box.innerHTML = '<p class="loading">Loading…</p>';
    try {
      await { health: sysHealth, backups: sysBackups, security: sysSecurity, data: sysData }[systemTab](box);
    } catch (err) {
      if (err.message !== 'Session ended') box.innerHTML = `<p class="notice error">${esc(err.message)}</p>`;
    }
  };
  $$('[data-tab]', main).forEach((b) => b.addEventListener('click', () => { systemTab = b.dataset.tab; draw(); }));
  await draw();
}

async function sysHealth(box) {
  const h = await api('GET', '/api/system/health');
  const st = h.stripe;
  const online = st.readers?.filter((r) => r.status === 'online').length ?? 0;
  const terminal = !st.configured ? 'Not set up' : st.error ? 'Error' : st.testMode ? 'Test mode' : 'Live';
  const kv = (rows) => `<table class="data compact kv">${rows.map(([k, v]) => `<tr><th>${k}</th><td>${v}</td></tr>`).join('')}</table>`;
  box.innerHTML = `
    ${h.warnings.length
      ? `<div class="notice"><strong>Needs attention</strong><ul>${h.warnings.map((w) => `<li>${esc(w)}</li>`).join('')}</ul></div>`
      : '<p class="notice ok">No problems found.</p>'}
    <div class="cards">
      <div class="stat"><span>Running for</span><strong>${fmtDuration(h.server.uptime_s)}</strong><small>since ${fmtDate(h.server.started_at)}</small></div>
      <div class="stat"><span>Database size</span><strong>${fmtBytes(h.database.size)}</strong><small>schema version ${h.database.schema_version}</small></div>
      <div class="stat"><span>Free disk space</span><strong>${h.disk ? fmtBytes(h.disk.free) : 'Unknown'}</strong>${h.disk ? `<small>of ${fmtBytes(h.disk.total)}</small>` : ''}</div>
      <div class="stat"><span>Last backup</span><strong>${h.backups.last ? fmtDate(h.backups.last.created_at) : 'None'}</strong><small>${h.backups.count} kept</small></div>
      <div class="stat"><span>Signed in</span><strong>${h.sessions}</strong><small>sessions</small></div>
      <div class="stat"><span>Card terminal</span><strong>${terminal}</strong><small>${st.readers ? `${online} of ${st.readers.length} readers online` : esc(st.error || '')}${st.latency_ms ? `, Stripe ${st.latency_ms} ms` : ''}</small></div>
    </div>
    <div class="report-grid">
      <section class="panel"><h2>Server</h2>${kv([
        ['Node.js', esc(h.server.node)], ['Operating system', esc(h.server.platform)], ['Computer', esc(h.server.host)],
        ['Memory used', `${h.server.memory_mb} MB`], ['Listening on', esc(h.server.listening)], ['Database file', `<code>${esc(h.database.path)}</code>`],
      ])}</section>
      <section class="panel"><h2>Records</h2>${kv(Object.entries(h.database.counts).map(([k, v]) => [esc(k.replace(/_/g, ' ')), v.toLocaleString()]))}</section>
      ${st.readers ? `<section class="panel"><h2>Card readers</h2>
        <table class="data compact"><thead><tr><th>Reader</th><th>Type</th><th>Status</th></tr></thead><tbody>
        ${st.readers.map((r) => `<tr><td>${esc(r.label)}</td><td>${esc(r.device_type)}</td><td><span class="badge ${r.status === 'online' ? 'completed' : 'refunded'}">${esc(r.status)}</span></td></tr>`).join('')
          || '<tr><td colspan="3" class="empty">No readers registered</td></tr>'}
        </tbody></table></section>` : ''}
      <section class="panel"><h2>Card payments in progress</h2>
        <table class="data compact"><thead><tr><th>Started</th><th>By</th><th class="num">Amount</th><th>Status</th><th></th></tr></thead><tbody>
        ${h.stuck_card_payments.map((c) => `<tr><td>${fmtDate(c.created_at)}</td><td>${esc(c.user_name)}</td><td class="num">${money(c.amount)}</td>
          <td>${esc(c.status)}${c.message ? `<div class="muted small">${esc(c.message)}</div>` : ''}</td>
          <td class="row-actions"><button data-check="${c.id}">Check</button><button data-cancel="${c.id}">Cancel</button></td></tr>`).join('')
          || '<tr><td colspan="5" class="empty">None waiting longer than 2 minutes</td></tr>'}
        </tbody></table></section>
      <section class="panel span-all"><h2>Recent server errors</h2>
        <table class="data compact"><thead><tr><th>When</th><th>Where</th><th>Error</th></tr></thead><tbody>
        ${h.errors.map((e) => `<tr><td class="nowrap">${fmtDate(e.at)}</td><td>${esc(e.context)}</td><td class="detail">${esc(e.message)}</td></tr>`).join('')
          || '<tr><td colspan="3" class="empty">No errors since the server started</td></tr>'}
        </tbody></table></section>
    </div>
    <div class="toolbar"><button id="refreshHealth">Refresh</button></div>`;
  $('#refreshHealth', box).addEventListener('click', () => sysHealth(box));
  box.querySelectorAll('[data-check], [data-cancel]').forEach((b) => b.addEventListener('click', async () => {
    try {
      const r = b.dataset.check
        ? await api('GET', `/api/terminal/payments/${b.dataset.check}`)
        : await api('POST', `/api/terminal/payments/${b.dataset.cancel}/cancel`);
      toast(r.status === 'succeeded' ? `Payment completed: sale #${receiptNo(r.sale.id)}` : `Payment is now ${r.status}`, 'success');
      sysHealth(box);
    } catch (err) { toast(err.message, 'error'); }
  }));
}

async function sysBackups(box) {
  const b = await api('GET', '/api/system/backups');
  box.innerHTML = `
    <div class="toolbar"><button class="primary" id="backupNow">Back up now</button><span class="spacer"></span></div>
    <p class="muted">An automatic backup is made once a day while the POS is running. The newest ${b.keep_auto} automatic backups are kept;
      manual backups are kept until you delete them. Backups are stored in <code>${esc(b.dir)}</code>.</p>
    <p class="notice">Backups on the same computer do not protect against disk failure, theft or fire. Download a backup at least once a week
      and keep it somewhere else, such as an encrypted USB drive.</p>
    <div class="table-wrap"><table class="data">
      <thead><tr><th>Backup</th><th>Type</th><th class="num">Size</th><th>Made</th><th></th></tr></thead>
      <tbody>${b.backups.map((x) => `<tr><td><code>${esc(x.name)}</code></td><td>${x.auto ? 'Automatic' : 'Manual'}</td>
        <td class="num">${fmtBytes(x.size)}</td><td>${fmtDate(x.created_at)}</td>
        <td class="row-actions"><button data-dl="${esc(x.name)}">Download</button><button class="ghost danger-text" data-del="${esc(x.name)}">Delete</button></td></tr>`).join('')
        || '<tr><td colspan="5" class="empty">No backups yet</td></tr>'}</tbody>
    </table></div>
    <section class="panel section-gap"><h2>How to restore a backup</h2>
      <ol class="steps">
        <li>Stop the POS (close the window running <code>npm start</code>, or press Ctrl+C in it).</li>
        <li>In the data folder, move <code>pos.db</code>, <code>pos.db-wal</code> and <code>pos.db-shm</code> to a safe place. Keep them until you are sure the restore worked.</li>
        <li>Copy the backup file into the data folder and rename it to <code>pos.db</code>.</li>
        <li>Start the POS and check the latest sales and the till.</li>
      </ol>
      <p class="muted small">Sales made after the backup was taken are not in it.</p>
    </section>`;
  $('#backupNow', box).addEventListener('click', async (e) => {
    e.target.disabled = true;
    try {
      const made = await api('POST', '/api/system/backups');
      toast(`Backup made (${fmtBytes(made.size)})`, 'success');
      sysBackups(box);
    } catch (err) { toast(err.message, 'error'); e.target.disabled = false; }
  });
  box.querySelectorAll('[data-dl]').forEach((btn) => btn.addEventListener('click', async () => {
    try { await download(`/api/system/backups/${encodeURIComponent(btn.dataset.dl)}`, btn.dataset.dl); } catch (err) { toast(err.message, 'error'); }
  }));
  box.querySelectorAll('[data-del]').forEach((btn) => btn.addEventListener('click', async () => {
    if (!(await confirmModal('Delete this backup?', `${btn.dataset.del} will be deleted permanently.`, { confirmLabel: 'Delete', danger: true }))) return;
    try { await api('DELETE', `/api/system/backups/${encodeURIComponent(btn.dataset.del)}`); sysBackups(box); } catch (err) { toast(err.message, 'error'); }
  }));
}

async function sysSecurity(box) {
  const [list, sec] = await Promise.all([api('GET', '/api/system/sessions'), api('GET', '/api/system/security')]);
  box.innerHTML = `
    <section class="panel"><h2>Signed in now</h2>
      <div class="table-wrap"><table class="data compact">
        <thead><tr><th>Who</th><th>Device</th><th>IP address</th><th>Signed in</th><th>Last active</th><th></th></tr></thead>
        <tbody>${list.map((s) => `<tr><td>${esc(s.user)} <span class="muted small">${s.role === 'admin' ? 'Manager' : 'Cashier'}</span></td>
          <td title="${esc(s.agent)}">${esc(deviceName(s.agent))}</td><td>${esc(s.ip)}</td>
          <td>${fmtDate(s.created_at)}</td><td>${fmtDate(s.last_seen)}</td>
          <td class="row-actions">${s.current ? '<span class="badge">This device</span>' : `<button data-end="${esc(s.sid)}">Sign out</button>`}</td></tr>`).join('')}</tbody>
      </table></div>
      <div class="actions"><button class="danger" id="endOthers" ${list.length > 1 ? '' : 'disabled'}>Sign out everyone else</button></div>
      <p class="muted small">Sign-ins are kept in memory, so everyone is signed out when the server restarts.</p>
    </section>
    <div class="report-grid section-gap">
      <section class="panel"><h2>Locked accounts</h2>
        <p class="muted small">An account locks for 5 minutes after 5 wrong PINs.</p>
        <table class="data compact"><thead><tr><th>Username</th><th class="num">Wrong PINs</th><th>Locked until</th><th></th></tr></thead><tbody>
        ${sec.locks.map((l) => `<tr><td>${esc(l.username)}</td><td class="num">${l.failures}</td><td>${l.locked_until ? fmtDate(l.locked_until) : 'Not locked'}</td>
          <td class="row-actions"><button data-unlock="${esc(l.username)}">${l.locked_until ? 'Unlock' : 'Clear'}</button></td></tr>`).join('')
          || '<tr><td colspan="4" class="empty">No accounts are locked</td></tr>'}
        </tbody></table></section>
      <section class="panel"><h2>Failed sign-ins, last 7 days</h2>
        <table class="data compact"><thead><tr><th>When</th><th>Username tried</th></tr></thead><tbody>
        ${sec.failed_logins.map((f) => `<tr><td>${fmtDate(f.created_at)}</td><td>${esc(f.username)}</td></tr>`).join('')
          || '<tr><td colspan="2" class="empty">None</td></tr>'}
        </tbody></table></section>
    </div>`;
  box.querySelectorAll('[data-end]').forEach((b) => b.addEventListener('click', async () => {
    try { await api('DELETE', `/api/system/sessions/${b.dataset.end}`); toast('Signed out', 'success'); sysSecurity(box); } catch (err) { toast(err.message, 'error'); }
  }));
  box.querySelectorAll('[data-unlock]').forEach((b) => b.addEventListener('click', async () => {
    try { await api('DELETE', `/api/system/locks/${encodeURIComponent(b.dataset.unlock)}`); toast('Account unlocked', 'success'); sysSecurity(box); } catch (err) { toast(err.message, 'error'); }
  }));
  $('#endOthers', box).addEventListener('click', async () => {
    if (!(await confirmModal('Sign out everyone else?', 'All other staff and tills are signed out and must sign in again. A card payment in progress is not affected.', { confirmLabel: 'Sign out everyone else', danger: true }))) return;
    try {
      const r = await api('POST', '/api/system/sessions/end-others');
      toast(`${r.ended} session(s) ended`, 'success');
      sysSecurity(box);
    } catch (err) { toast(err.message, 'error'); }
  });
}

async function sysData(box) {
  const demo = await api('GET', '/api/system/demo');
  box.innerHTML = `
    <div class="report-grid">
      <section class="panel"><h2>Full data export</h2>
        <p>Downloads every table as a CSV file in one ZIP file, for your accountant, an audit or moving to another system.
          Staff PINs are left out.</p>
        <p class="muted small">This is a copy for reading. To restore the POS, use a backup instead.</p>
        <button class="primary" id="exportAll">Download export (.zip)</button>
      </section>
      <section class="panel"><h2>Integrity check</h2>
        <p>Checks the database file, and that sales, refunds, stock and till records all agree with each other.</p>
        <button class="primary" id="runCheck">Run check</button>
        <div id="checkResult"></div>
      </section>
      <section class="panel span-all"><h2>Demo data</h2>
        ${demo.length ? `<p>These products came with the POS as examples. Products that were never sold are deleted.
            Products that appear in sales are switched off instead, so past receipts stay correct.</p>
          <table class="data compact"><thead><tr><th>SKU</th><th>Name</th><th>Will be</th></tr></thead><tbody>
          ${demo.map((p) => `<tr><td>${esc(p.sku)}</td><td>${esc(p.name)}</td><td>${p.action === 'delete' ? 'Deleted' : 'Switched off (has sales)'}</td></tr>`).join('')}
          </tbody></table>
          <div class="actions"><button class="danger" id="clearDemo">Remove demo data</button></div>`
          : '<p class="muted">No demo products left.</p>'}
      </section>
    </div>`;
  $('#exportAll', box).addEventListener('click', async (e) => {
    e.target.disabled = true;
    try { await download('/api/system/export', 'pos-export.zip'); } catch (err) { toast(err.message, 'error'); }
    e.target.disabled = false;
  });
  $('#runCheck', box).addEventListener('click', async (e) => {
    e.target.disabled = true;
    try {
      const r = await api('POST', '/api/system/integrity');
      $('#checkResult', box).innerHTML = `<p class="notice ${r.ok ? 'ok' : 'error'}">${r.ok ? 'All checks passed.' : 'Some checks found problems.'}</p>
        <ul class="checks">${r.checks.map((c) => `<li class="${c.ok ? 'pass' : 'fail'}">
          <span class="badge ${c.ok ? 'completed' : 'refunded'}">${c.ok ? 'Pass' : 'Fail'}</span> <strong>${esc(c.name)}</strong>
          <span class="muted small">${esc(c.description)}</span>
          ${c.ok ? '' : `<ul>${c.issues.map((i) => `<li>${esc(i)}</li>`).join('')}${c.count > c.issues.length ? `<li>and ${c.count - c.issues.length} more</li>` : ''}</ul>`}
        </li>`).join('')}</ul>`;
    } catch (err) { toast(err.message, 'error'); }
    e.target.disabled = false;
  });
  $('#clearDemo', box)?.addEventListener('click', async () => {
    if (!(await confirmModal('Remove demo data?', 'This cannot be undone. Make a backup first if you are unsure.', { confirmLabel: 'Remove', danger: true }))) return;
    try {
      const r = await api('POST', '/api/system/demo/clear');
      toast(`${r.deleted} deleted, ${r.deactivated} switched off`, 'success');
      sysData(box);
    } catch (err) { toast(err.message, 'error'); }
  });
}

// ---------- AUDIT LOG
const AUDIT_LABELS = {
  login: 'Signed in', logout: 'Signed out', login_failed: 'Failed sign-in', pin_changed: 'PIN changed',
  settings_changed: 'Settings changed', category_created: 'Category added', category_deleted: 'Category deleted',
  product_created: 'Product added', product_updated: 'Product changed', stock_adjusted: 'Stock adjusted',
  discount_applied: 'Discount given', sale_refunded: 'Sale refunded', sales_exported: 'Sales exported',
  user_created: 'Staff added', user_updated: 'Staff changed',
  till_opened: 'Till opened', till_closed: 'Till closed', cash_paid_in: 'Cash paid in', cash_paid_out: 'Cash paid out',
  card_payment_cancelled: 'Card payment cancelled', terminal_location_created: 'Terminal location added',
  terminal_reader_registered: 'Card reader added', terminal_reader_removed: 'Card reader removed',
  backup_created: 'Backup made', backup_downloaded: 'Backup downloaded', backup_deleted: 'Backup deleted',
  session_ended: 'Session signed out', sessions_ended: 'Other sessions signed out', account_unlocked: 'Account unlocked',
  data_exported: 'Full data export', integrity_check: 'Integrity check run', demo_data_cleared: 'Demo data removed',
};

async function renderAudit(main) {
  main.innerHTML = `<h1>Audit log</h1>
    <p class="muted">A permanent record of sign-ins, price and stock changes, discounts, refunds and staff changes.</p>
    ${rangeBar()}
    <div class="table-wrap"><table class="data">
      <thead><tr><th>When</th><th>Who</th><th>Action</th><th>Detail</th></tr></thead><tbody id="aBody"></tbody>
    </table></div>`;
  const getRange = wireRange(main, () => load());
  const load = async () => {
    const rows = await api('GET', `/api/audit?${getRange().query}`);
    $('#aBody').innerHTML = rows.map((r) => `<tr>
      <td class="nowrap">${fmtDate(r.created_at)}</td><td>${esc(r.user_name || '')}</td>
      <td>${esc(AUDIT_LABELS[r.action] || r.action)}</td><td class="detail">${esc(r.detail || '')}</td></tr>`).join('')
      || '<tr><td colspan="4" class="empty">No entries in this period</td></tr>';
  };
  await load();
}

boot();
