# StoreFlow POS — Development Progress

**Last updated:** 2026-11-03
**Current phase:** Phase 4 complete; Phase 5 next
**Schema version:** 1
**Tests:** 262 passing (`flutter test`), `flutter analyze` clean

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
| 5 | Customers and financial management | Not started |
| 6 | Multi-currency | Partially implemented (currency model, per-invoice rates and split payments are in place; a currency-management UI and historical-rate screens are not) |
| 7 | Printing and barcode hardware | Not started |
| 8 | Reports and dashboard | Not started |
| 9 | Backup and security | Not started |
| 10 | Final quality assurance | Not started |

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
