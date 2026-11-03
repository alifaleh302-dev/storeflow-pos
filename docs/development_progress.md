# StoreFlow POS — Development Progress

**Last updated:** 2026-11-03
**Current phase:** Phase 1 complete; Phase 2 next
**Schema version:** 1

This report states what is implemented, what is tested, and what is not. A
feature is only listed as done when its code path runs against the real database
and is covered by a test that was actually executed.

---

## Phase status

| Phase | Description | Status |
|---|---|---|
| 0 | Environment inspection | **Complete** — see `environment_report.md` |
| 1 | Project foundation | **Complete** |
| 2 | Products and inventory foundation | Not started |
| 3 | Sales and POS | Not started |
| 4 | Purchasing and suppliers | Not started |
| 5 | Customers and financial management | Not started |
| 6 | Multi-currency | Not started |
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
