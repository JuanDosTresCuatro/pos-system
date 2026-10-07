# POS

A standard point of sale system for a single shop. It runs in a web browser and needs only Node.js 22.13 or later. It has no third-party dependencies.

## Roblox version

The [roblox](roblox/) folder has RoPOS, a version of this POS for Roblox experiences, built with Rojo. It uses the same pricing rules. See [roblox/README.md](roblox/README.md).

## Start

```sh
npm start
```

Open http://localhost:3000 and sign in with username `admin`, PIN `1234`. **Change this PIN immediately** (top right, "Change PIN").

The first start loads demo products. To start with an empty catalogue, delete the `data` folder and run `SEED_DEMO=0 npm start` (PowerShell: `$env:SEED_DEMO='0'; npm start`).

## Features

| Area | What it does |
| --- | --- |
| Sell | Product grid with category filter, search, barcode scanner input (scanners that type and press Enter), quantity edit, order discount, cash (with change calculation), and card payment on a Stripe Terminal reader or a separate card machine |
| Receipts | On-screen receipt, print to an 80 mm receipt printer or any printer, reprint from sales history. Card receipts show card type, last 4 digits, AID, application name and auth code. Refunds are listed on the receipt |
| Sales | History by date range, find by receipt number. Full or partial refunds by item and quantity: to cash, back to the original card through Stripe, or by hand on a separate card machine. Choose whether returned items go back into stock |
| Till | Open with a float, pay cash in or out with a reason, X report at any time, blind count at close with a coin and note counter, Z report showing over or short. Managers see past sessions |
| Products | SKU, barcode, category, price, cost, tax rate, stock tracking, low-stock warning, deactivate. Stock adjustments with reason and full movement history |
| Reports | Net takings, refunds, tax, discounts, gross profit and margin, payments by method, sales by cashier, top products, low stock. CSV export and print |
| Staff | Manager and cashier roles, 4 to 8 digit PINs, disable accounts. Sign-in locks for 5 minutes after 5 wrong PINs |
| Settings | Store details, currency and locale, tax name and rate, tax-inclusive or tax-exclusive pricing, cashier discount limit, allow or block sales at zero stock, card payment mode, Stripe Terminal locations and readers |
| Audit log | Sign-ins, failed sign-ins, price and product changes, stock adjustments, discounts, refunds, cash paid in and out, till open and close with variance, cancelled card payments, reader changes, backups, exports, system actions and staff changes, with who and when |
| System | Health dashboard with warnings, backups, signed-in sessions, account unlocks, full data export, integrity check, demo data removal. See [System panel](#system-panel) |

### Roles

- **Cashier:** open and close the till (blind count: expected cash is shown only after counting), pay cash in and out, sell, view sales history and reprint receipts, view products, give discounts up to the configured limit.
- **Manager:** everything above, plus refunds, products, stock, reports, past till sessions, staff, settings, the audit log and the System panel.

## Card payments with Stripe Terminal

Card data never passes through this POS. The customer taps or inserts their card on the Stripe reader, Stripe processes it, and the POS records the sale only after Stripe confirms the payment.

### Set up (start in test mode)

1. Create a Stripe account. In the Stripe Dashboard, copy your **test** secret key (it starts with `sk_test_`).
2. Copy `.env.example` to `.env` in the POS folder and set `STRIPE_SECRET_KEY`. Restart the POS. The start-up message says "Stripe TEST mode".
3. Sign in as a manager and open **Settings**. Under **Card payments**, choose "Stripe Terminal reader" and save.
4. In the **Stripe Terminal** panel, add a location (the shop address), then add a reader with the registration code `simulated-wpe`. This creates a simulated reader.
5. Sell something and press **Card**. In test mode the payment window has **Simulate approved card** and **Simulate declined card** buttons.

### Go live

1. Order a reader from the Stripe Dashboard (Stripe Reader S700 or BBPOS WisePOS E).
2. Put your **live** key in `.env` and restart. Use `sk_live_`, or better, a restricted `rk_live_` key with write access to Terminal, PaymentIntents and Refunds. The start-up message says "Stripe LIVE mode".
3. Add a location and register the reader with the pairing code shown on its screen.
4. Take one small real payment, refund it, and check both in the Stripe Dashboard before you start trading.

Check Stripe's current in-person card fees for your country on their pricing page before going live.

### How it behaves

- **Declined card:** the cashier sees the reason and can try again or cancel. Nothing is recorded until a payment succeeds.
- **Cancel:** cancels on the reader and in Stripe. If the customer paid just before the cancel arrived, the POS records the sale instead of losing it.
- **Browser closed or page reloaded mid-payment:** the payment window comes back when the cashier returns to Sell. The server also checks unfinished payments every 20 seconds, so a successful payment is always recorded. Payments still waiting after 15 minutes are cancelled.
- **One payment per reader:** a second payment on a busy reader is refused.
- **Refunds:** for sales paid on the reader, managers can refund all or part of the sale back to the original card. The money normally reaches the customer in 5 to 10 working days.
- **Several tills:** the "Default" reader applies to every till. "This till" in the readers table overrides it on one device.

## Till sessions

A till must be open before taking payments. Open it with the float and close it by counting the drawer.

Expected cash = float + cash sales - cash refunds + cash paid in - cash paid out.

Cashiers count blind. The Z report then shows whether the drawer is over or short, and the result is written to the audit log. The POS assumes one cash drawer, so only one till session can be open at a time.

## System panel

Managers open **System** in the top menu. It has four tabs.

- **Health:** a list of anything that needs attention, then server uptime, database size, free disk space, last backup, number of signed-in sessions, card terminal and reader status, and record counts. It warns about accounts still on PIN 1234, a database in a cloud-synced folder, missing or old backups, low disk space (under 500 MB), offline card readers, and card payments left in progress for more than 2 minutes (with buttons to check or cancel them). It also lists the last 50 server errors since the server started.
- **Backups:** make a backup now, download or delete backups, and step-by-step restore instructions. An automatic backup is made once a day while the POS runs, and the newest 14 automatic backups are kept. Manual backups are kept until you delete them.
- **Sessions and security:** who is signed in, on which device and IP address, and when they were last active. Sign out one session or everyone else. Unlock accounts locked after 5 wrong PINs. Failed sign-ins from the last 7 days.
- **Data tools:** download every table as CSV in one ZIP file (staff PINs left out). Run an integrity check that confirms the database file is sound and that sales, refunds, stock levels and till sessions all agree with each other. Remove the demo products: unsold ones are deleted, and ones that appear in sales are switched off so old receipts stay correct.

Every action in the System panel is written to the audit log.

## Using it on more than one device

By default the server only accepts connections from this computer. To use tablets or other tills on the same network, start it with `HOST=0.0.0.0` (PowerShell: `$env:HOST='0.0.0.0'; npm start`) and open `http://<this-computer's-IP>:3000`. Traffic is not encrypted, so do this only on a trusted private network, or put the server behind an HTTPS reverse proxy.

## Data and backups

All data is in one SQLite file, `data/pos.db`. Set `POS_DATA_DIR` to store it elsewhere.

- This project is currently inside OneDrive. Cloud sync can corrupt a database that is in use, so for real trading set `POS_DATA_DIR` to a folder outside OneDrive.
- The POS backs itself up once a day to `data/backups` (set `AUTO_BACKUP=0` to turn this off). You can also back up from **System > Backups** at any time without stopping the POS.
- Backups on the same computer do not protect against disk failure or theft. Download one at least once a week and keep it somewhere else.
- The database upgrades itself when a new version of the POS starts. Back up before you update.
- Keep `.env` private. It holds your Stripe key, and anyone with a live secret key can move money on your Stripe account.

## Tests

```sh
npm test
```

Runs the pricing unit tests, end-to-end API tests (sales, refunds, till sessions, permissions, System panel), a database migration test, and the card terminal flow against a mock Stripe server. The mock follows Stripe's documented behaviour. It does not replace one test payment through real Stripe test mode before going live.

## Known limits

- One payment method per sale. Split payments (for example part cash, part card) are not supported.
- Exchanges are done as a refund plus a new sale.
- No Stripe webhooks. The POS polls Stripe instead, which works without exposing the POS to the internet. If a card refund fails at the bank after Stripe accepted it (rare), you see this in the Stripe Dashboard, not in the POS.
- One shop, one database, one cash drawer. No multi-site sync or offline mode.
- Sign-in sessions are kept in memory, so staff sign in again after a server restart.
- Money is stored as whole minor units (for example pence) to avoid rounding errors. Tax is calculated per line and rounded to the nearest minor unit.

## Project layout

```
server.js              HTTP server, API routes, validation, card payment tracking
src/db.js              SQLite schema and migrations, settings, PIN hashing, first-run seed
src/stripe.js          Stripe Terminal client (payments, readers, refunds)
src/backup.js          Online backups, daily automatic backup and clean-up
src/integrity.js       Database and record consistency checks
src/zip.js             ZIP writer for the full data export
public/index.html      App page
public/js/app.js       Front end (all screens)
public/js/pricing.js   Totals and tax calculation, shared by browser and server
public/css/styles.css  Styles, including the 80 mm receipt print layout
test/                  Automated tests and the mock Stripe server
.env.example           Template for the Stripe key and other settings
```
