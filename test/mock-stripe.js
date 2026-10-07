// A small stand-in for the parts of the Stripe API the POS uses.
// It mimics Stripe's documented behaviour for server-driven Terminal; it is not Stripe.
import http from 'node:http';

export function startMockStripe() {
  const intents = new Map();
  const readers = new Map([['tmr_mock1', { id: 'tmr_mock1', object: 'terminal.reader', label: 'Till 1', device_type: 'simulated_wisepos_e', status: 'online', serial_number: 'SIM-1', location: 'tml_1', action: null }]]);
  const locations = [{ id: 'tml_1', display_name: 'Shop', address: { line1: '1 High St', city: 'Leeds', postal_code: 'LS1 1AA', country: 'GB' } }];
  const refunds = [];
  let seq = 0;
  const err = (res, status, message, code) => send(res, status, { error: { message, code } });
  const send = (res, status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };

  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const url = new URL(req.url, 'http://x');
      const p = Object.fromEntries(new URLSearchParams(req.method === 'GET' ? url.search : raw));
      const parts = url.pathname.replace(/^\/v1\//, '').split('/');
      if (req.headers.authorization !== 'Bearer sk_test_mock') return err(res, 401, 'Invalid API key');

      // terminal locations and readers
      if (url.pathname === '/v1/terminal/locations') {
        if (req.method === 'GET') return send(res, 200, { data: locations });
        const loc = { id: `tml_${++seq}`, display_name: p.display_name, address: { line1: p['address[line1]'] } };
        locations.push(loc);
        return send(res, 200, loc);
      }
      if (url.pathname === '/v1/terminal/readers') {
        if (req.method === 'GET') return send(res, 200, { data: [...readers.values()] });
        if (!p.registration_code.startsWith('simulated')) return err(res, 400, 'Invalid registration code');
        const r = { id: `tmr_${++seq}`, label: p.label, device_type: 'simulated_wisepos_e', status: 'online', location: p.location, action: null };
        readers.set(r.id, r);
        return send(res, 200, r);
      }
      if (parts[0] === 'terminal' && parts[1] === 'readers') {
        const reader = readers.get(parts[2]);
        if (!reader) return err(res, 404, 'No such reader');
        if (!parts[3] && req.method === 'GET') return send(res, 200, reader);
        if (!parts[3] && req.method === 'DELETE') { readers.delete(reader.id); return send(res, 200, { deleted: true }); }
        if (parts[3] === 'process_payment_intent') {
          if (reader.action?.status === 'in_progress') return err(res, 409, 'Reader is busy', 'terminal_reader_busy');
          reader.action = { type: 'process_payment_intent', status: 'in_progress', process_payment_intent: { payment_intent: p.payment_intent } };
          return send(res, 200, reader);
        }
        if (parts[3] === 'cancel_action') { reader.action = null; return send(res, 200, reader); }
      }
      if (parts[0] === 'test_helpers') {
        const reader = readers.get(parts[3]);
        const pi = intents.get(reader?.action?.process_payment_intent?.payment_intent);
        if (!pi) return err(res, 400, 'Reader has no action');
        if (p['card_present[number]'] === '4000000000000002') {
          reader.action.status = 'failed';
          reader.action.failure_code = 'card_declined';
          reader.action.failure_message = 'Your card was declined.';
          pi.last_payment_error = { message: 'Your card was declined.' };
        } else {
          reader.action.status = 'succeeded';
          pi.status = 'succeeded';
          pi.latest_charge = {
            id: `ch_${++seq}`, authorization_code: null,
            payment_method_details: { card_present: {
              brand: 'visa', last4: '4242', read_method: 'contactless_emv',
              receipt: { application_preferred_name: 'Visa Credit', dedicated_file_name: 'A0000000031010', authorization_code: '123456' },
            } },
          };
        }
        return send(res, 200, reader);
      }

      // payment intents and refunds
      if (url.pathname === '/v1/payment_intents' && req.method === 'POST') {
        const pi = { id: `pi_${++seq}`, amount: Number(p.amount), currency: p.currency, status: 'requires_payment_method', latest_charge: null, refunded: 0 };
        intents.set(pi.id, pi);
        return send(res, 200, pi);
      }
      if (parts[0] === 'payment_intents') {
        const pi = intents.get(parts[1]);
        if (!pi) return err(res, 404, 'No such payment_intent');
        if (!parts[2]) return send(res, 200, pi);
        if (parts[2] === 'cancel') {
          if (pi.status === 'succeeded') return err(res, 400, 'You cannot cancel this PaymentIntent because it has a status of succeeded.');
          pi.status = 'canceled';
          return send(res, 200, pi);
        }
      }
      if (url.pathname === '/v1/refunds' && req.method === 'POST') {
        const pi = intents.get(p.payment_intent);
        const amount = Number(p.amount);
        if (!pi || pi.status !== 'succeeded') return err(res, 400, 'PaymentIntent has not succeeded');
        if (pi.refunded + amount > pi.amount) return err(res, 400, 'Refund is greater than unrefunded amount on charge');
        pi.refunded += amount;
        const r = { id: `re_${++seq}`, amount, status: 'succeeded', payment_intent: pi.id };
        refunds.push(r);
        return send(res, 200, r);
      }
      return err(res, 404, `Mock has no route for ${req.method} ${url.pathname}`);
    });
  });

  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => {
    resolve({ base: `http://127.0.0.1:${server.address().port}/v1`, refunds, intents, readers, close: () => server.close() });
  }));
}
