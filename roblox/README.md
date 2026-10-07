# RoPOS

A point of sale system for Roblox experiences: cafés, shops, restaurants and any roleplay game where staff sell to players.

Staff walk up to a register and ring up an order. The customer approves the payment on their own screen, the money moves, stock goes down, the items appear in their backpack and both players get a receipt. Managers get shift reports, refunds, price and stock control, 7-day reports and an audit log. Everything is saved and shared across every server of the game.

It is the Roblox version of the web POS in the parent folder, and uses the same pricing rules and rounding.

## Start here

Pick the one that fits you. None of them need you to write code.

### 1. Try it in a browser (no Roblox needed, 1 minute)

Double-click [`simulator/index.html`](simulator/index.html). It opens in any browser and works offline.

You play the staff on the left and the customers on the right:

1. The page opens with Ann (a manager) at the till, a shift open, and 2 lattes and a croissant in the order for Bob.
2. Press **Charge $76**. Bob's screen on the right shows the bill.
3. Press **Pay $76** on Bob's screen. Bob's Cash drops, the items land in his backpack and both sides get a receipt.
4. Work through **Things to try** under the simulator: declines, a customer who can't afford it, a price change mid-payment, refunds, the cashier's limits and the Z report.

The **Server log** at the bottom shows every request and its result, the same messages the real server sends.

The simulator is a faithful browser copy of the RoPOS rules for trying things out. The real Roblox code is tested separately (see [Test without Roblox](#test-without-roblox)).

### 2. Play it in Roblox Studio (5 minutes)

1. Install [Roblox Studio](https://create.roblox.com/) if you don't have it.
2. Open [`RoPOS.rbxlx`](RoPOS.rbxlx) from this folder (double-click it, or File > Open in Studio).
3. Press **Play** (F5). A café counter appears in front of you.
4. Walk round the back of the counter and hold **E** on the till. The POS window opens.
5. Go to the **Shift** tab and press **Open shift**.
6. On **Sell**, tap some products, press **Choose customer**, pick yourself and press **Charge**.
7. Your own payment screen pops up. Press **Pay**. The items appear in your backpack and Cash goes down (top right).

During Studio play tests everyone is a manager and you can charge yourself, so you can try everything alone. To test with a separate cashier and customer, use **Test > Clients and Servers** with 2 players.

Nothing is saved between play tests until you publish the place and turn on **Game Settings > Security > Enable Studio Access to API Services**. Until then the POS header shows "Studio: data not saved".

### 3. Put it in your own game

1. Open your place in Studio.
2. Open `RoPOS.rbxlx` as well, and copy these 3 folders across into the same places in your game:
   - `ReplicatedStorage > POS`
   - `ServerScriptService > POSServer`
   - `StarterPlayer > StarterPlayerScripts > POSClient`
3. Edit `ReplicatedStorage > POS > Config` to set your shop name, products, prices, staff and currency. Every setting is explained in the file.
4. Press Play. If your map has no register yet, RoPOS builds a demo counter so you can test straight away. Then tag your own till model `POSRegister` and turn off `Config.Demo.SpawnRegister` (see [Your own registers](#your-own-registers)).
5. Before you publish, set who your staff are: `Config.Staff.GroupId` and the ranks, or user IDs in `Config.Staff.Users`. Set `Config.Staff.StudioRole = nil` to test the real rules in Studio.

Developers who prefer files and Git can sync with Rojo instead (see [Development](#development)).

## How a sale works in game

| Who | Does what |
| --- | --- |
| Cashier | Holds **E** on the till, opens a shift, taps products, chooses the customer standing at the counter, presses **Charge** |
| Till screen | Shows the customer the item count and total, then "Please approve" |
| Customer | Gets a payment screen with the bill, their balance before and after, and a 30-second countdown. Presses **Pay** or **Decline** |
| Server | Checks the price again, takes the money and the stock, puts the items in the customer's backpack, records the sale |
| Both | Get a paper-style receipt. The till screen says "Thank you!" |
| Manager | Refunds from the **Sales** tab, edits prices and stock on **Products**, reads **Reports** and the **Audit log** |

## Features

| Area | What it does |
| --- | --- |
| Registers | Tag any Model or Part `POSRegister` to make a till. Proximity prompt for staff, a customer-facing screen in the world that shows the live order total, "Please approve" and "Thank you!", and automatic sign-out when the cashier walks away |
| Sell | Product grid with search, category chips, stock badges and in-cart counters. Quantity steppers, discount presets limited by role, live totals, a nearby-customer picker and a waiting screen with countdown and cancel |
| Payment | The customer sees an itemised bill, their balance before and after, and a countdown. They choose Pay or Decline. Nothing is charged without their approval |
| Receipts | Paper-style receipt for cashier and customer. Look up any receipt by number |
| Refunds | Managers refund a full sale, with or without restocking. The money returns to the customer even if they are offline or on another server |
| Shifts | Open a shift to take payments. Live X report at any time, Z report on close: sales, items, gross, discounts, tax, refunds, net, average sale, top items, sales by cashier |
| Products | Managers change prices, adjust stock and take items off sale in the game. Changes reach every server |
| Reports | 7-day net takings bar chart, totals, best sellers and top cashiers across all servers |
| Audit log | Sales, discounts, refunds, price and stock changes, shift open and close, with who and when |
| Roles | Customer, Cashier and Manager, from a Roblox group rank or a list of user IDs. Cashiers have a discount limit |
| Currency | Built-in saved currency, or plug in your game's existing leaderstats value |
| Tax | Optional, per product, tax-inclusive or tax-exclusive |

## How it works

```
 Cashier client                      Server                              Customer client
 ──────────────                      ──────                              ───────────────
 Sell screen ── checkout.start ────▶ validate cart, role, distance
 (live totals from                   price from live catalogue
  shared Pricing)                    create pending order ── PaymentRequest ──▶ bill + countdown
                                                                               Pay / Decline
                                     ◀───────────────────── checkout.respond ──
                                     re-price (must match)
                                     debit wallet ┐ one step,
                                     take stock   ┘ no yields
                                     record sale, give Tools,
 receipt ◀──────── OrderUpdate ───── update shift and reports ── Receipt ─────▶ receipt
                                     register screen: "Thank you!"
```

- **Server-authoritative.** The client sends only product IDs and quantities. The server prices every order from its own catalogue and re-prices on approval. If anything changed, the payment is cancelled instead of charging a different amount.
- **One API, one router.** A single `RemoteFunction` carries every request as an action name (`"sales.refund"`). The router rate-limits each player, checks the role the action needs, runs it in a `pcall` and returns `{ ok, data }` or `{ ok = false, error }`. Internal errors are logged and never sent to the client.
- **The server never calls `InvokeClient`.** Server-to-client traffic goes through one `RemoteEvent`, so a client cannot hang a server thread.
- **Shared pricing.** `Pricing.luau` runs on both sides, so the cart preview always matches the charge. It is a port of `public/js/pricing.js`, and the test suite runs the same cases as the web POS tests.

### Data and multiple servers

Each server keeps a queue of *changes* and applies them inside `UpdateAsync` transforms, so many servers can write the same key without overwriting each other. Writes are batched every 20 seconds and on shutdown.

| DataStore | Key | Contents | How it is written |
| --- | --- | --- | --- |
| `RoPOS_Wallets_v1` | `u<UserId>` | balance | Change since last save, so a refund from another server is merged |
| `RoPOS_Catalogue_v1` | `products` | price, on sale, stock per product | Queued operations (`stock -2`), versioned, other servers told by MessagingService |
| `RoPOS_Sales_v1` | `counter` | last receipt number | Atomic increment |
| | `s/<receipt>` | full sale | Once, then the refund flag. The transform refuses a second refund |
| | `recent` | latest 200 sale summaries | Merged |
| `RoPOS_Reports_v1` | `d/<YYYY-MM-DD>` | daily totals (UTC) | Per-day totals merged |
| `RoPOS_Shifts_v1` | `z/<shiftId>` | Z report | Once |
| `RoPOS_Audit_v1` | `log` | latest 500 actions | Merged |

Change `Config.Data.Scope` to start again with empty data.

### Security model

- Every remote argument is type-checked and range-checked (`Validate.luau`). Carts are capped, merged and rejected if malformed.
- Roles are resolved on the server only. The client hides staff prompts for customers, but the server checks the role on every action.
- Cashiers are limited to `Config.Discounts.CashierMaxPct`. Refunds, prices, stock, reports and the audit log need a manager.
- The customer must be within `CustomerRange` of the register, must approve the payment themselves, and can have only one payment waiting.
- The wallet debit and the stock decrement happen in one step with no yields, so two payments cannot spend the same money or the last item.

## Project layout

```
roblox/
├── default.project.json      Rojo project: where each folder goes in the place
├── rokit.toml                Pinned tool versions (rojo, selene, stylua, luau-lsp)
├── src/
│   ├── shared/               ReplicatedStorage.POS
│   │   ├── Config.luau       All settings and the product list
│   │   ├── Pricing.luau      Line pricing (client preview and server totals)
│   │   ├── Validate.luau     Remote input checks
│   │   ├── Aggregate.luau    Report totals that merge across servers
│   │   ├── Format.luau       Money, dates, receipt rows
│   │   ├── Roles.luau, Signal.luau, Net.luau
│   ├── server/               ServerScriptService.POSServer
│   │   ├── init.server.luau  Start-up order
│   │   ├── Handlers.luau     Every client action and the role it needs
│   │   └── Services/         Store, Api, Staff, Wallet, Catalogue, Checkout,
│   │                         Registers, Shifts, Sales, Reports, Audit, Demo
│   └── client/               StarterPlayerScripts.POSClient
│       ├── App.luau          Window, header, tabs, screen scaling
│       ├── PaymentPrompt.luau, Receipt.luau, Api.luau, State.luau
│       ├── UI/               Theme tokens, UI kit, toasts
│       └── Screens/          Sell, Sales, Shift, Products, Reports, Audit
├── tests/
│   ├── Specs.luau            Unit specs for the pure modules (Luau CLI and Studio)
│   ├── simulate.luau         End-to-end run of the server code on 2 fake servers (Lune)
│   └── sim/                  The fake Roblox engine and loader used by simulate.luau
├── simulator/index.html      Browser simulator, no Roblox needed
└── RoPOS.rbxlx               Ready-to-open place file (built with `rojo build`)
```

## Configuration

Everything is in `src/shared/Config.luau`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `Store.Name`, `ReceiptPrefix`, `Footer` | Brickbrew Café, `BB` | Shown on screens and receipts |
| `Currency.Provider` | `"Builtin"` | `"Leaderstats"` uses a value your game already creates and saves |
| `Currency.StatName`, `Symbol`, `StartingBalance` | `Cash`, `$`, 500 | |
| `Tax.Enabled`, `Inclusive` | off, inclusive | Rate is per product (`TaxRate`) |
| `Staff.GroupId`, `ManagerRank`, `CashierRank` | 0, 250, 10 | Group ranks for roles. `Users` overrides by UserId |
| `Staff.StudioRole` | `"Manager"` | Role for everyone in play tests. `nil` uses the normal rules |
| `Discounts.Presets`, `CashierMaxPct` | 0 to 50, 10 | |
| `Checkout.CustomerRange` | 16 studs (about 4.5 m) | How close the customer must stand |
| `Checkout.OperatorRange` | 20 studs (about 5.6 m) | Cashier is signed out beyond this |
| `Checkout.PaymentTimeout` | 30 s | Time the customer has to approve |
| `Checkout.AllowSelfCheckout` | `"Studio"` | Let staff charge themselves |
| `Checkout.GiveItems` | on | Clone `ServerStorage.POSItems[Tool]` into the customer's Backpack |
| `Payouts.CashierCommissionPct` | 0 | Pays cashiers a share of each sale. This creates currency, so plan for it |
| `Demo.SpawnRegister`, `CreateItemTools` | on | Build the demo counter and placeholder Tools if none exist |

### Products

```lua
{ Id = "latte", Name = "Caramel Latte", Category = "Coffee", Price = 28, TaxRate = 20,
  Stock = 30, Colour = Color3.fromRGB(201, 150, 99), Tool = "Caramel Latte" },
```

`Id` must never change, because sales and stock refer to it. Leave out `Stock` for items that are not stock-tracked. `Tool` is the name of a Tool in `ServerStorage.POSItems`. Put your real modelled items there and RoPOS gives them to the customer.

### Your own registers

1. Make a Model (or a single Part) for the till.
2. Add the tag `POSRegister` (Properties > Tags, or the Tag Editor).
3. Optional attributes: `RegisterId` (stable ID) and `RegisterName` (for example "Drive-thru").
4. Optional: a Part named `Screen` inside the model. Its **front** face shows the customer display. Without one, a floating display appears above the register.

Turn off `Config.Demo.SpawnRegister` once you have your own.

### Reading roles from other scripts

Every player gets a `POSRole` attribute (`"Customer"`, `"Cashier"` or `"Manager"`), so doors, uniforms and staff-only areas can use the same rules.

## Test without Roblox

`tests/simulate.luau` runs the **real** RoPOS server code, every module unchanged, on 2 simulated game servers that share one set of DataStores. Fake players walk up to the counter, ring up orders, pay, decline, get refunds and change servers. 101 checks cover permissions, malformed requests, payments, timeouts, a price changing mid-payment, stock sold on 2 servers at once, a refund to a player who left, 2 managers refunding the same sale at the same moment, reports, rate limiting and a DataStore outage.

```sh
rokit install          # once: installs lune and the other tools from rokit.toml
lune run tests/simulate
```

It ends with `RoPOS simulation: 101 passed, 0 failed`. The fake engine (`tests/sim/Engine.luau`) is stricter than Roblox in one useful way: it fails on anything a RemoteEvent or DataStore would refuse, such as a mixed table or a Color3 saved to a DataStore.

## Development

```sh
rokit install                                   # rojo, selene, stylua, luau-lsp, lune
lune run tests/simulate                         # end-to-end run of the server code (no Roblox)
luau tests/run.luau                             # unit tests (Luau CLI)
selene src tests                                # lint
stylua --check src tests                        # formatting
rojo sourcemap -o sourcemap.json
luau-lsp analyze --definitions=globalTypes.d.luau --sourcemap=sourcemap.json src tests
rojo build -o RoPOS.rbxlx                       # rebuild the place file after changing code
rojo serve                                      # live sync into Studio with the Rojo plugin
```

The same specs also run in the Output window at the start of every Studio play test. `globalTypes.d.luau` comes from the [luau-lsp repository](https://github.com/JohnnyMorganz/luau-lsp/tree/main/scripts).

## Studio acceptance checklist

Run this in a **Local Server** test with 2 players (Test > Clients and Servers), and record the result before you release:

| # | Step | Expected |
| --- | --- | --- |
| 1 | Player 1 holds E on the till | POS window opens on Sell, shift shows "closed" |
| 2 | Open a shift | Header pill turns green, register screen shows "Welcome!" |
| 3 | Add 2 lattes and 1 cookie | Totals update, register screen shows "3 items" and the total |
| 4 | Player 2 stands at the counter, Player 1 chooses them and presses Charge | Player 2 sees the bill with countdown, the screen shows "Please approve" |
| 5 | Player 2 presses Pay | Both get a receipt, Player 2's Cash goes down, Tools appear in Player 2's backpack, cookie stock goes down by 1 |
| 6 | Charge again and Player 2 presses Decline | Player 1 sees "declined", nothing is charged |
| 7 | Charge again and wait 30 s | Payment expires on both sides |
| 8 | Sales tab, open the receipt, Refund with restock | Player 2 gets the money back, stock returns, the receipt shows REFUNDED |
| 9 | Try to refund the same receipt again | Refused |
| 10 | Shift tab, Close shift | Z report shows 1 sale and 1 refund, net 0 |
| 11 | Open the till again, then walk more than 20 studs (about 5.6 m) away | Window closes, register screen shows "Closed" |
| 12 | Reports and Audit log tabs | The sale, refund and shift actions are listed |
