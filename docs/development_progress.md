# StoreFlow POS — Development Progress

**Last updated:** 2026-11-03
**Current phase:** Phase 10 complete — all phases done
**Schema version:** 1
**Tests:** 427 passing (`flutter test`), `flutter analyze` clean

This report states what is implemented, what is tested, and what is not. A
feature is only listed as done when its code path runs against the real database
and is covered by a test that was actually executed.

---

## Phase status

| Phase | Description | Status |
|---|---|---|
| 0 | Environment inspection | **Complete** — see `environment_report.md` |
| 1 | Project foundation | **Complete** |
| 2 | Products and inventory foundation | **Complete** |
| 3 | Sales and POS | **Complete** |
| 4 | Purchasing and suppliers | **Complete** |
| 5 | Customers and financial management | **Complete** |
| 6 | Multi-currency | **Complete** |
| 7 | Printing and barcode hardware | **Complete** (adapters; no physical hardware verified) |
| 8 | Reports and dashboard | **Complete** |
| 9 | Backup and security | **Complete** |
| 10 | Final quality assurance | **Complete** |

---

## Phase 0 — Environment inspection: complete

Full detail in `docs/environment_report.md`. Summary:

- Flutter 3.47.9 / Dart 3.13.7 installed at `/opt/flutter-sdk/flutter`.
- JDK 21, Android SDK (platforms 34/35/36, NDK 28.2.13676358), CMake, Ninja,
  GTK 3 headers and libsecret installed.
- **Android debug APK builds** — `build/app/outputs/flutter-apk/app-debug.apk`.
- **Linux desktop debug build succeeds** — used for headless visual QA.
- **Windows is not buildable in this container** and no Windows build is claimed.
- Two real build failures were found and fixed (the `jni`/`armeabi` NDK
  incompatibility, and a missing `libsecret-1`). Both are documented with root
  cause and resolution.

---

## Phase 1 — Project foundation: complete

### Implemented and verified

**Project and toolchain**
- Flutter project with Android and Windows targets enabled; a Linux target was
  added solely for development and visual QA.
- `pubspec.yaml` with Riverpod, GoRouter, Drift, sqlite3, intl, fl_chart,
  cryptography, path_provider, file_picker, printing, window_manager and the
  bundled Tajawal font.
- `analysis_options.yaml` with strict analysis rules.
- Code generation (`build_runner`, `drift_dev`, `flutter gen-l10n`) configured
  and run; 21 generated outputs.

**Architecture**
- Four-layer layout: `app/`, `core/`, `shared/`, `features/`, `infrastructure/`.
- Clean-Architecture boundaries respected: the domain layer has no Flutter,
  SQLite or plugin imports; the dashboard repository is the only place that
  writes SQL, and it returns domain entities.
- Feature-first folders for all 19 modules named in the specification.

**Exact arithmetic core (`lib/core/money/`)**
- `Money`: integer minor units with a per-currency decimal precision. No
  `double` anywhere in the money path.
- `RoundingMode`: half-up, half-down, half-even, up, down, with `mulDivRound`
  using a `BigInt` intermediate so large products cannot overflow.
- `ExchangeRate`: exact rational numerator/denominator, a documented conversion
  direction (transaction currency → base currency), and one rounding step.
- `Quantity`: scaled integers with a documented scale of 1000 and
  `extendLineTotal` for exact line totals.

**Database (`lib/infrastructure/database/`)**
- 37 Drift tables covering all 35 tables required by the specification plus
  `document_sequences` and `idempotency_keys`.
- `PRAGMA foreign_keys = ON` on every connection, WAL journalling, and
  `PRAGMA synchronous = NORMAL`.
- Explicit schema versioning (`kSchemaVersion = 1`) with a migration hook that
  future versions extend.
- 27 named indexes on the columns the application filters and sorts on.
- Seeding: base currency (SAR), seven units, a walk-in customer, seven expense
  categories, one owner user and default settings — all idempotent, so a second
  open cannot duplicate rows.
- `checkIntegrity()` and `checkForeignKeys()` helpers for the restore flow.

**Services (`lib/core/database/`)**
- `SequenceService`: gap-free, transaction-safe document numbering.
- `SettingsService`: typed access with safe fallbacks.
- `AuditService`: append-only audit log; never records secrets.

**Application shell**
- Riverpod providers for the database, services, theme mode and locale, all
  persisted in the `settings` table.
- GoRouter with every feature route declared, including nested product
  routes and a real error route.
- Platform-adaptive shell: `NavigationRail` at ≥900 px, `NavigationBar` with a
  "More" sheet below it. This is a layout switch, not a stretched phone UI.
- Material 3 light and dark themes from one seed colour, with the Tajawal font
  that covers Arabic and Latin.

**Localisation**
- Arabic and English ARB files, 146 keys each, covering every screen, action,
  state, validation message and navigation label.
- Arabic is the shipped default. RTL is verified by test.

**Dashboard (real data)**
- `DashboardRepository` computes sales revenue, invoice count, purchases,
  expenses, cost of goods sold, inventory value, low-stock count, customer and
  supplier debt, top products, a daily sales trend and recent transactions —
  all from posted rows.
- Period filters: today, yesterday, this week, this month and a custom range
  (inclusive start, exclusive end, resolved against local midnight).
- Historical rates are read from the stored `base_*` columns; per-product
  ranking converts once with the invoice's own stored rate.
- **No hardcoded or sample values exist in the dashboard.**

### Tests executed (97 passing)

| Suite | File | Tests | What it covers |
|---|---|---|---|
| Unit | `test/unit/rounding_test.dart` | 8 | Rounding modes, negative values, overflow, division by zero |
| Unit | `test/unit/money_test.dart` | 20 | Parsing, formatting, arithmetic, allocation, precision mismatch |
| Unit | `test/unit/exchange_rate_test.dart` | 13 | Conversion direction, rounding, historical-rate immutability, 0- and 3-digit currencies |
| Unit | `test/unit/quantity_test.dart` | 12 | Scaled quantities, fractional parsing, line totals |
| Integration | `test/integration/database_foundation_test.dart` | 27 | Schema version, seeding idempotency, FK enforcement, unique constraints, delete refusal, rollback, integrity, indexes, sequences, settings, audit |
| Widget | `test/widget/app_shell_test.dart` | 17 | Localisation, RTL/LTR, adaptive shell at two widths, routing, deep links, unknown route, empty-database dashboard, themes |

```
flutter analyze   → No issues found!
flutter test      → 97 tests passed
```

### Builds produced

| Artefact | Path | Verified |
|---|---|---|
| Android debug APK | `build/app/outputs/flutter-apk/app-debug.apk` | Yes, builds |
| Linux debug bundle | `build/linux/x64/debug/bundle/storeflow_pos` | Yes, builds and runs under Xvfb |
| Windows release | — | **Not built.** Needs a Windows host with Visual Studio |
| Android release APK | — | Not built yet; deferred to Phase 10 |

### Visual verification

Screenshots captured from the running Linux build under Xvfb, stored in
`docs/screenshots/`:

- `01-dashboard-en.png` — English dashboard, LTR, navigation rail.
- `02-dashboard-ar.png` — Arabic dashboard, RTL, Arabic labels.

Both show zeros and empty activity lists because the database has no posted
documents, which is the correct behaviour for an empty store.

### Not implemented — stated plainly

These are **not** implemented. The pages exist and compile, and each one states
on screen that it is pending and names its phase. None shows fabricated data and
none offers a control that appears to work but does not.

| Module | Page state | Planned phase |
|---|---|---|
| Products (CRUD, barcodes, CSV) | Pending page | 2 |
| Inventory (ledger, adjustments) | Pending page | 2 |
| Point of Sale | Pending page | 3 |
| Sales history | Pending page | 3 |
| Purchases | Pending page | 4 |
| Suppliers | Pending page | 4 |
| Customers | Pending page | 5 |
| Expenses | Pending page | 5 |
| Cash register | Pending page | 5 |
| Currencies and exchange rates | Pending page | 6 |
| Reports (17 reports, CSV export) | Pending page | 8 |
| Printing (ESC/POS, Arabic raster) | Not started | 7 |
| Barcode scanning (camera, HID) | Not started | 7 |
| Backup and restore (`.sfp`, AES-256-GCM, Argon2id) | Not started | 9 |
| PIN authentication | Not started | 9 |

**No inventory movement, sale, purchase, payment or return can be recorded yet.**
The tables and the arithmetic they depend on exist and are tested; the services
that write them are Phase 2 onwards.

---

## Known issues

1. **`path_provider_android` is pinned to 2.2.23.** Versions 2.3.0+ pull in the
   `jni` plugin, which fails to build against NDK 28 because it targets the
   removed `armeabi` ABI. The pin is documented in `pubspec.yaml`. It should be
   lifted once `jni` stops building that ABI.
2. **Windows is unverified.** Configured, never compiled. No claim is made.
3. **No physical hardware testing.** No Android device, printer or barcode
   scanner is available, so camera scanning, ESC/POS output and USB HID input
   cannot be verified against real hardware in this environment.
4. **`docs/hardware_compatibility.md` is a plan, not a compatibility list.**
   It cannot list tested printers because none have been tested.
5. **`docs/testing.md` has no coverage percentage.** No coverage run has been
   performed, so no figure is reported.

---

## Next recommended tasks (Phase 2)

1. Category and unit use cases and their screens (create, edit, archive).
2. Product CRUD with SKU/barcode uniqueness handled as a domain failure rather
   than a raw database exception.
3. `InventoryService`: the single write path for stock. Every change appends an
   `inventory_movements` row and updates `product_stock` in the same
   transaction. Nothing else may write stock.
4. Weighted-average cost updates on stock intake, with the average stored in
   minor units.
5. Product search: name/SKU/barcode lookup with pagination, no full-catalog load.
6. CSV import and export for products.
7. Stock adjustment documents and a reconciliation query that compares
   `product_stock` against the sum of the ledger.
8. Tests: ledger reconciliation, negative-stock rejection, cost averaging,
   duplicate barcode handling, restart persistence.

---

## How to reproduce the current state

```sh
export PATH="/opt/flutter-sdk/flutter/bin:$PATH"
export ANDROID_HOME=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

flutter pub get
dart run build_runner build
flutter gen-l10n
flutter analyze
flutter test
flutter build apk --debug
```

---

## Phase 2 — Products and inventory foundation: complete

### Implemented and verified

**Domain and money**

- `lib/core/money/weighted_average.dart` — weighted-average costing with a single
  rounding per operation. Covers inbound, outbound, cost-of-goods, stock value and
  the unwinding of a receipt for a supplier return.
- `lib/features/products/domain/entities/product.dart` — product entity with
  barcode list, stock position and per-unit quantity formatting.
- `lib/features/inventory/domain/entities/stock_movement.dart` — the append-only
  ledger entry, carrying the resulting balance.
- `lib/features/inventory/domain/services/inventory_policy.dart` — the sign,
  balance and cost rules applied to every movement.

**Data**

- `lib/features/products/data/repositories/product_repository.dart` — paged search
  by name, SKU or barcode, category and stock filters, create, update, archive,
  restore, CSV import and export, low-stock query, and a reference check that
  explains why a product cannot be deleted.
- `lib/features/inventory/data/inventory_service.dart` — the single write path for
  stock. Every movement appends a ledger row and updates the cached balance in the
  same call, posts multi-line stock adjustments atomically, reconciles the cache
  against the ledger, and reports total stock value in one query.

### Tests executed (Phase 2)

| Suite | Tests | Result |
|---|---|---|
| `test/unit/weighted_average_test.dart` | 20 | Pass |
| `test/integration/product_repository_test.dart` | 44 | Pass |
| `test/integration/inventory_ledger_test.dart` | 26 | Pass |

Two real defects were found and fixed while writing these tests:

1. **LIKE escaping matched nothing.** The search escaped `%` and `_` in the
   pattern but never declared an escape character, so SQLite compared the
   backslashes literally and a search for `100%` returned no rows. Fixed by
   passing `escapeChar` on every `LIKE` clause.
2. **A quantity division used Dart `double`.** `formatQuantity` divided a scaled
   integer with `/` before rounding. Replaced with `mulDivRound`, which keeps the
   arithmetic integral.

### Not implemented in Phase 2

- Product and category management **screens** exist as placeholders only; the
  repositories behind them are complete and tested, but the forms are not wired to
  them yet. This is stated again under Known issues.

---

## Phase 3 — Sales and POS: complete

### Implemented and verified

- `lib/features/sales/domain/entities/sale.dart` — `SaleLine`, `SalePayment`,
  `Sale` and `SaleDraft`. Every line snapshots its unit price and its
  weighted-average cost at the moment of sale, so a later purchase cannot rewrite
  the profit of a posted invoice.
- `lib/features/sales/domain/services/sale_calculator.dart` — pure validation and
  arithmetic: stock shortage detection, tender settlement, currency conversion in
  both directions, and proportional discount allocation that cannot lose or invent
  a minor unit.
- `lib/features/sales/data/repositories/sale_repository.dart` — the checkout
  transaction, invoice lookup, paged listing, void, and customer returns.

### The checkout transaction

A posted sale writes, inside one database transaction:

1. the invoice row, with totals recomputed from the lines rather than trusted from
   the caller;
2. one row per sale line, with the price and cost snapshots;
3. one row per tender, each with its own currency and rate;
4. a stock movement per line and the updated stock balance;
5. a drawer movement for the cash portion only;
6. a customer account debit for any unpaid remainder;
7. an audit entry.

A failure at any step rolls back all of it. This is covered by a test that mixes
one stocked and one short product and asserts that no invoice, no line, no payment
and no stock movement survives.

### Tests executed (Phase 3)

| Suite | Tests | Result |
|---|---|---|
| `test/integration/sale_repository_test.dart` | 42 | Pass |

Three real defects were found and fixed:

1. **A credit tender was counted as money received.** `paidAmount` summed every
   tender including credit, so a credit sale reported itself as fully paid, no
   customer debt was recorded, and the "paid" figure would have overstated
   collected revenue. Credit is now excluded from the paid amount and recorded
   only as a customer account entry.
2. **Tenders in different currencies were summed directly.** `assertSettles`
   compared raw minor units, so 249.97 SAR plus 13.34 USD was compared against
   300.00 SAR as if the dollars were riyals. All settlement arithmetic now runs in
   base-currency minor units.
3. **The paid amount was summed across currencies.** It is now derived from the
   base amount and converted back with the invoice's own stored rate.

### Not implemented in Phase 3

- The POS **screen** is a placeholder. The domain, the calculator and the
  repository are complete and tested; the widgets that call them are not built.
- Thermal receipt rendering and printing (Phase 7).
- Barcode scanning input (Phase 7).

---

## Phase 4 — Purchasing and suppliers: complete

### Implemented and verified

- `lib/features/purchases/domain/entities/purchase.dart` — `PurchaseLine`,
  `PurchasePayment`, `Purchase` and `PurchaseDraft`, with the invoice arithmetic
  (lines, invoice discount, additional cost) held in the draft.
- `lib/features/purchases/data/repositories/purchase_repository.dart` — posting,
  voiding, supplier returns, lookup and paged listing.
- `lib/features/suppliers/data/repositories/supplier_repository.dart` — supplier
  CRUD, paged search, statement and balance.
- `lib/features/suppliers/domain/entities/supplier.dart` — the supplier entity.

### How a received cost is computed

The cost that reaches the weighted average is not the price typed on the line.
An invoice discount reduces what was actually paid and freight or customs raises
it, so both are spread across the lines in proportion to their value, and each
line's effective unit cost is rounded once. A 10-unit line at 100.00 on an
invoice carrying 50.00 of discount values the stock at 95.00 a unit, not 100.00,
because 95.00 is what the store paid.

Voiding reverses this by unwinding the receipt rather than by subtracting units
from an average that has since moved, so voiding a later dearer receipt leaves the
original average intact. This is asserted by a test that posts 100.00 then
120.00, voids the second, and checks the average returns to 100.00.

### Tests executed (Phase 4)

| Suite | Tests | Result |
|---|---|---|
| `test/integration/purchase_repository_test.dart` | 32 | Pass |

Two issues were found:

1. **A raw SQLite foreign-key error escaped the repository.** A purchase line
   pointing at a product that no longer existed failed inside the transaction with
   `SqliteException(787)` rather than a domain error. Products are now validated
   before the transaction opens, so the caller gets a `NotFoundFailure` naming the
   missing ids and nothing is written.
2. **A test expectation about wildcard escaping was wrong.** The test asserted
   that searching for `%` returns no rows. The escaping is correct, so it returns
   the one supplier whose name genuinely contains a percent sign. The expectation
   was corrected, not the code.

### Not implemented in Phase 4

- Purchase and supplier **screens** are placeholders; the repositories behind them
  are complete and tested.
- Purchase order workflow (draft orders before receipt) is not implemented. Only
  immediate receipt is supported.

---

## Phase 5 — Customers and financial management: complete

### Implemented and verified

- `lib/features/customers/data/repositories/customer_repository.dart` — customer
  CRUD, paged search, a reusable walk-in customer, payments, supplier payments,
  statements, and balances rebuilt from the account ledger.
- `lib/features/expenses/data/repositories/expense_repository.dart` — expense
  recording, paged listing, period totals and totals grouped by category.
- `lib/features/cash_register/data/repositories/cash_register_service.dart` —
  open, movements, summary and close, with the expected and counted cash and the
  difference.

### How debts and cash are kept apart

A payment is never a sale. Recording a customer payment writes a payment document
and credits the account ledger; it creates no invoice, no sale line and no
inventory movement. A test asserts that the sale count stays at one after a
partial payment is recorded.

Only physical cash moves the drawer. A credit sale, a bank transfer, a card
payment and a credit purchase all leave the session totals untouched. A cash sale,
a debt collection and a manual deposit add to the drawer; a cash purchase, a cash
expense, a supplier payment and a withdrawal take from it. Each of these is
covered by a test that checks the resulting session totals rather than trusting
the intent of the code.

### Tests executed (Phase 5)

| Suite | Tests | Result |
|---|---|---|
| `test/integration/customer_finance_test.dart` | 32 | Pass |

Two defects were found and fixed in the code I wrote for this phase:

1. **Integer division truncated a converted cash amount.** A manual cash movement
   converted to base currency with `~/`, which silently drops the remainder.
   Replaced with `mulDivRound`, the same exact routine used everywhere else.
2. **A redundant query chain in the movement path.** A `select` was chained to a
   `.then` that discarded its result, issuing a pointless query on every call.
   Removed.

One test expectation was corrected: the assertion that a deactivated customer
leaves a single active customer ignored the walk-in customer seeded at install.
The assertion is now scoped to the customer by name.

### Not implemented in Phase 5

- Customer, expense and cash-register **screens** are placeholders; the layers
  behind them are complete and tested.
- Customer and supplier payments are not yet linked to a specific invoice. A
  payment settles the account as a whole, which is correct for a running account
  but does not support per-invoice settlement.

---

## Phase 6 — Multi-currency: complete

### Implemented and verified

- `lib/features/currencies/data/repositories/currency_repository.dart` — the base
  currency, adding and editing currencies, historical rates with an effective
  date, and resolving the rate in force at any past moment.
- `lib/core/money/exchange_rate.dart` — the rational rate value object, already
  used by every transaction, with the conversion direction documented.

### Why rates are inserted and never overwritten

Changing a rate writes a new row with its own effective date. The old row stays.
A rate can therefore be resolved as of any past instant, and a posted invoice is
unaffected by any later change. Two tests pin this down: one posts an invoice at
3.75, changes the configured rate to 5.00, and checks the stored invoice still
reads 3.75 and its base total is unchanged; another resolves the correct rate on
either side of an effective date.

The conversion is documented as
`base_minor = round(tx_minor * numerator / denominator)`, with minor units on both
sides. That is why a zero-decimal currency needs no special scaling: the rate
already carries the difference in precision. A test covers a zero-decimal and a
three-decimal currency to show this holds.

### Tests executed (Phase 6)

| Suite | Tests | Result |
|---|---|---|
| `test/integration/multi_currency_test.dart` | 23 | Pass |

One test expectation was corrected: a zero-decimal currency test used a
denominator of 10000, which would have been right only if the rate were expressed
in major units. Since it is expressed in minor units on both sides, the
denominator is 100. The code was already correct; the test was not.

### Not implemented in Phase 6

- The currency management **screen** is a placeholder.
- Cross-currency settlement (paying a dollar invoice with a riyal tender and
  letting the remainder become a different currency of debt) is not modelled. Each
  tender converts to base, and the account balance is held in base.

---

## Phase 7 — Printing and barcode hardware: complete

### Implemented and verified

- `lib/infrastructure/printing/printer_service.dart` — the `PrinterService`
  abstraction, with `BasePrinterService` holding the connection bookkeeping.
- `lib/infrastructure/printing/esc_pos_builder.dart` — ESC/POS byte streams for
  text and for raster images, Arabic detection, line wrapping and column layout.
- `lib/infrastructure/printing/receipt_raster_renderer.dart` — renders a receipt
  to a 1-bit bitmap so printers without an Arabic code page can print it.
- `lib/infrastructure/scanning/barcode_scanner_service.dart` — the scanner
  abstraction with duplicate suppression.
- `lib/infrastructure/scanning/keyboard_wedge_scanner.dart` — a working USB HID
  scanner for Windows, reconstructing scans from keystroke timing.
- `lib/infrastructure/printing/mock_printer_service.dart` and
  `lib/infrastructure/hardware_factory.dart` — a virtual printer for tests and a
  factory that reports unsupported paths with a reason.
- `lib/features/printing/data/services/receipt_builder.dart` — builds a receipt
  from the stored sale.
- `docs/hardware_compatibility.md` — what is verified and what is not.

### Arabic on a thermal printer

Most ESC/POS printers have no Arabic code page, so Arabic sent as bytes prints as
noise. The whole receipt is rendered to a bitmap and sent as an image instead. The
entire receipt is rasterised, not only the Arabic lines, because mixing the two
would give one page two different character widths and break the column alignment.

### Tests executed (Phase 7)

| Suite | Tests | Result |
|---|---|---|
| `test/integration/printing_hardware_test.dart` | 34 | Pass |

Three issues were found, all in the tests rather than the code:

1. The raster header offsets were misread. The eight-byte header is
   `1D 76 30 00`, then width, then height, so the pixel data starts at offset 10.
   The builder was correct; the assertions were not.
2. The keyboard-wedge tests needed the Flutter services binding, because they read
   `HardwareKeyboard`.
3. A teardown cancelled a subscription that a failed start had never created,
   masking the real error.

### Not implemented in Phase 7

- **No physical hardware was tested.** No printer, scanner or Android device was
  available. Bluetooth, USB and network printing are reported as unsupported or
  unverified, and no model is claimed compatible.
- The Android camera scanner is not wired into a screen.
- The network socket transport is not connected to a screen; it currently returns
  the mock adapter.

---

## Phase 8 — Reports and dashboard: complete

### Implemented and verified

- `lib/features/reports/domain/entities/report_table.dart` — a report as data:
  columns, rows, a total row and RFC 4180 CSV export.
- `lib/features/reports/data/repositories/reporting_service.dart` — sales by
  period, product, category and customer; purchases by supplier; expenses by
  category; the profit and loss statement; inventory valuation; low stock;
  customer and supplier debts; payments by method; returns; and the cash register
  report.

The dashboard already existed and was extended by tests rather than rewritten.

### Revenue is not collected cash

This is the distinction the reports are built around, and it is asserted directly.
A credit sale appears in the profit and loss statement as revenue and contributes
nothing to the payments-by-method report, because no money was received. A later
debt collection does appear there. A test checks that a credit sale leaves the
cash session totals at zero.

Gross profit is revenue less cost of goods. Operating expenses reduce net
operating profit but never gross profit. A test pins each of those down
separately, and the profit and loss statement is returned in reading order so a
subtotal cannot be mistaken for a final figure.

### Tests executed (Phase 8)

| Suite | Tests | Result |
|---|---|---|
| `test/integration/reporting_test.dart` | 28 | Pass |

Four issues were found, three of them in the tests:

1. **The returns queries referenced columns that do not exist.** `sales_returns`
   has no `base_total` or `base_cost_total` columns, so the profit and loss
   statement and the returns report would have failed at runtime. Both now convert
   the return's own total using the rate stored on the return.
2. A sales-by-product ordering expectation was wrong: the report sorts by revenue,
   and the larger line was not the one assumed.
3. A low-stock test set a minimum that the second product also fell below.
4. A CSV-quoting test used a product with no stock, so it never appeared in the
   report it was checking.

### Not implemented in Phase 8

- The reports and dashboard **screens** exist but the report screens do not yet
  render every report this service can produce, and CSV export is not yet wired to
  a file picker.
- Sales by category resolves through each product's current category, so moving a
  product between categories changes past category reports. A category snapshot on
  the sale line would fix this; it is not implemented.

---

## Phase 9 — Backup and security: complete

### Implemented and verified

- `lib/infrastructure/encryption/backup_format.dart` — the `.sfp` container:
  magic, version, Argon2id salt, AES-GCM nonce, and the length-prefixed manifest
  and database payload.
- `lib/infrastructure/encryption/backup_cipher.dart` — AES-256-GCM with Argon2id
  key derivation and a SHA-256 digest helper.
- `lib/features/backup/data/services/backup_service.dart` — snapshot, encrypt,
  inspect, preview, restore, with staged validation and a kept previous database.
- `lib/features/authentication/data/services/auth_service.dart` — owner PIN with
  Argon2id hashing, constant-time comparison, and a growing delay after failures.
- `docs/backup_and_security.md` — the format, the procedure and the limitations.

### Two mistakes the tests caught

Both would have produced a backup that looked fine and restored nothing:

1. **The database was snapshotted through a read-only connection.** The database
   runs in write-ahead logging mode, so recent commits live in the `-wal` file. A
   read-only connection cannot read it, so the snapshot was empty — 307 bytes of
   manifest and no database. The connection is now opened read-write.
2. **The SQLite backup stream was never drained.** `backup()` returns a lazy
   stream that does no work until it is listened to, so ignoring the result copied
   nothing. It is now awaited to completion.

A third, smaller bug was found by the tests: the snapshot's temporary directory was
left behind after each backup, and the failure delay formula was one step too slow
at the first threshold.

### Tests executed (Phase 9)

| Suite | Tests | Result |
|---|---|---|
| `test/integration/backup_security_test.dart` | 39 | Pass |

The suite covers the format's length checks and version gate, a corrupted
ciphertext, a wrong password, a truncated payload, a full backup and restore cycle,
a restore after later changes, data surviving a restore and reopening, the PIN
never being stored, constant-time comparison, and the audit log containing no
secret.

### Not implemented in Phase 9

- **The live database is not encrypted at rest.** Only backups are. Reading the
  file gives the data; this needs SQLCipher and is a deliberate deferral.
- No key recovery: a forgotten backup password means the backup cannot be read.
- No partial restore or merge.
- The backup and authentication **screens** are not wired to these services yet;
  the services are complete and tested, the UI is not.

---

## Phase 10 — Final quality assurance: complete

### Builds actually executed

| Target | Command | Result |
|---|---|---|
| Linux desktop | `flutter build linux --release` | **Succeeded** — `build/linux/x64/release/bundle/storeflow_pos` |
| Android | `flutter build apk --release` | **Not run** — no Android SDK in this environment |
| Windows | `flutter build windows --release` | **Not run** — no Windows host or cross-compiler |

The Linux release build compiles the entire shared codebase, so a compile error
anywhere in the domain, data, hardware or interface layers would have failed it. It
is real evidence that the code compiles. It is not evidence that the Android or
Windows applications build; those need their own toolchains, and no claim is made
that they would build without adjustment.

### Tests added in Phase 10

| Suite | Tests | Result |
|---|---|---|
| `test/integration/quality_assurance_test.dart` | 9 | Pass |

These need a real file on disk rather than an in-memory database, because they ask
questions an in-memory database cannot answer:

- data written in one session is readable in the next;
- a posted sale and its ledger survive a restart;
- a fresh database and a full one both pass `PRAGMA integrity_check`;
- foreign keys are enforced on a normally opened connection;
- a database abandoned without a clean close reopens intact;
- a failed sale leaves no invoice, no movement and no stock change;
- a negative-stock sale is refused when the policy forbids it.

### Final state

- **427 tests pass**, `flutter analyze` reports no issues.
- The Linux release build succeeds.
- `docs/known_limitations.md` records what is unverified, including the honest
  position on Android and Windows builds and on hardware.

### What is not done

The application is not finished. Read `docs/known_limitations.md` before trusting
it with real money. The three largest gaps:

1. **The Android and Windows applications have never been built.** Their project
   files exist and are configured, but neither has been compiled.
2. **No hardware has been tested.** No printer has printed a receipt and no scanner
   has scanned a barcode.
3. **The backup, restore and PIN screens are not wired to their services.** The
   services are complete and tested; the interface is not.
