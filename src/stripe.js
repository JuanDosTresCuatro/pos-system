// Minimal Stripe REST client for server-driven Stripe Terminal.
// The secret key comes from the environment only and is never sent to the browser.
// STRIPE_API_BASE exists only so automated tests can point at a mock server.
const API = process.env.STRIPE_API_BASE || 'https://api.stripe.com/v1';

export class StripeError extends Error {
  constructor(message, status, code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

const key = () => process.env.STRIPE_SECRET_KEY || '';
export const stripeConfigured = () => /^(sk|rk)_(test|live)_/.test(key());
export const stripeTestMode = () => /^(sk|rk)_test_/.test(key());

// Stripe expects form encoding with bracketed keys: a[b]=1, list[0]=x.
function encode(params, prefix = '', out = new URLSearchParams()) {
  for (const [k, v] of Object.entries(params ?? {})) {
    if (v === undefined || v === null) continue;
    const name = prefix ? `${prefix}[${k}]` : k;
    if (typeof v === 'object') encode(v, name, out);
    else out.append(name, String(v));
  }
  return out;
}

async function call(method, path, params, idempotencyKey) {
  if (!stripeConfigured()) throw new StripeError('Stripe is not set up. Set STRIPE_SECRET_KEY and restart the server.', 503);
  const query = method === 'GET' && params ? `?${encode(params)}` : '';
  let res;
  try {
    res = await fetch(`${API}${path}${query}`, {
      method,
      headers: {
        Authorization: `Bearer ${key()}`,
        'Content-Type': 'application/x-www-form-urlencoded',
        ...(idempotencyKey && { 'Idempotency-Key': idempotencyKey }),
      },
      body: method === 'GET' ? undefined : encode(params).toString(),
      signal: AbortSignal.timeout(20_000),
    });
  } catch (err) {
    throw new StripeError(`Could not reach Stripe (${err.name === 'TimeoutError' ? 'timed out' : 'network error'})`, 504);
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new StripeError(data.error?.message || `Stripe returned HTTP ${res.status}`, res.status, data.error?.code);
  return data;
}

// ---------- locations and readers
export const listLocations = () => call('GET', '/terminal/locations', { limit: 100 }).then((r) => r.data);
export const createLocation = (displayName, address) =>
  call('POST', '/terminal/locations', { display_name: displayName, address });
export const listReaders = () => call('GET', '/terminal/readers', { limit: 100 }).then((r) => r.data);
export const getReader = (id) => call('GET', `/terminal/readers/${encodeURIComponent(id)}`);
export const registerReader = (registrationCode, label, location) =>
  call('POST', '/terminal/readers', { registration_code: registrationCode, label, location });
export const deleteReader = (id) => call('DELETE', `/terminal/readers/${encodeURIComponent(id)}`);
export const cancelReaderAction = (id) => call('POST', `/terminal/readers/${encodeURIComponent(id)}/cancel_action`);

// ---------- payments
export const createPaymentIntent = ({ amount, currency, description, metadata }, idempotencyKey) =>
  call('POST', '/payment_intents', {
    amount,
    currency: currency.toLowerCase(),
    payment_method_types: ['card_present'],
    capture_method: 'automatic',
    description,
    metadata,
  }, idempotencyKey);

export const getPaymentIntent = (id) =>
  call('GET', `/payment_intents/${encodeURIComponent(id)}`, { expand: ['latest_charge'] });
export const capturePaymentIntent = (id) => call('POST', `/payment_intents/${encodeURIComponent(id)}/capture`);
export const cancelPaymentIntent = (id) => call('POST', `/payment_intents/${encodeURIComponent(id)}/cancel`);

export const processOnReader = (readerId, paymentIntentId) =>
  call('POST', `/terminal/readers/${encodeURIComponent(readerId)}/process_payment_intent`, { payment_intent: paymentIntentId });

export const createRefund = ({ paymentIntent, amount, metadata }, idempotencyKey) =>
  call('POST', '/refunds', { payment_intent: paymentIntent, amount, metadata }, idempotencyKey);

// Test mode only: acts as a customer tapping a card on a simulated reader.
// 4000000000000002 is Stripe's generic-decline test card.
export const simulateCardTap = (readerId, decline = false) =>
  call('POST', `/test_helpers/terminal/readers/${encodeURIComponent(readerId)}/present_payment_method`,
    decline ? { card_present: { number: '4000000000000002' } } : {});

// Card fields to print on the receipt (UK card schemes expect AID and application name).
export function cardDetails(paymentIntent) {
  const charge = typeof paymentIntent.latest_charge === 'object' ? paymentIntent.latest_charge : null;
  const card = charge?.payment_method_details?.card_present || {};
  const receipt = card.receipt || {};
  return {
    brand: card.brand || null,
    last4: card.last4 || null,
    readMethod: card.read_method || null,
    appName: receipt.application_preferred_name || null,
    aid: receipt.dedicated_file_name || null,
    authCode: receipt.authorization_code || charge?.authorization_code || null,
  };
}
