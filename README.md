# StoreFlow POS

An offline-first Point of Sale and inventory management system for small retail
shops, built with Flutter for **Android** and **Windows**.

No internet connection, no cloud account and no subscription are required. All
data stays in a local SQLite database on the device.

> **Project status: the service layer is complete; the user interface is not.**
> The foundation — architecture, exact-arithmetic money layer, database schema,
> localisation, theming, routing, the adaptive shell and a database-backed
> dashboard — is implemented and tested (435 passing tests), and so are the
> domain, data and hardware-service layers for every feature below.
> **The business screens are not built.** Point of Sale, products, purchases,
> customers, suppliers, expenses, cash register, reports, printing, barcode
> scanning and backup have complete, tested services but no working interface:
> each of those pages currently states on screen that it is pending, and only the
> dashboard reads real data. The application therefore cannot yet ring up a sale
> from the interface. See
> [`docs/known_limitations.md`](docs/known_limitations.md) for the honest
> position and [`docs/development_progress.md`](docs/development_progress.md) for
> the per-module status.

## Features

### Implemented — user interface

Only the dashboard has a working screen.

- **Dashboard** with ten live figures, a sales trend chart, top products and
  recent activity — all computed from posted rows, with no sample data.
- **Period filters:** today, yesterday, this week, this month, custom range.
- **Arabic and English**, Arabic by default, with correct RTL layout.
- **Platform-adaptive UI:** navigation rail on wide windows, bottom navigation
  on phones. Not a stretched phone layout.
- **Material 3** light and dark themes, with the Tajawal font for Arabic and
  Latin.

### Implemented — services, with no screen yet

These are written and tested against the real database, but no page drives them.
Their routes exist and show a "pending" message.

- **Exact money arithmetic.** Integer minor units with per-currency precision.
  No `double` anywhere in the money path.
- **Exact quantities.** Scaled integers at a documented scale of 1000.
- **Multi-currency.** Rational exchange rates with a documented conversion
  direction and historical immutability.
- **Database.** 37 tables, 27 indexes, foreign keys enforced, WAL journalling,
  versioned schema, idempotent seeding.
- **Append-only ledgers** for inventory movements, customer accounts and
  supplier accounts.
- **Sales, purchasing, inventory, customers, suppliers, expenses, cash register
  and reporting services**, including atomic checkout and gap-free invoice
  numbers.
- **Printing and scanning adapters**: ESC/POS receipt building with an Arabic
  raster renderer, and a keyboard-wedge barcode parser.
- **Encrypted backup and restore** (`.sfp`, AES-256-GCM, Argon2id).

### Not built

- Every screen for the services listed above — Point of Sale, products,
  categories, units, barcodes, inventory, purchases, suppliers, customers,
  debts, expenses, cash register, the 17 reports with CSV export, printing,
  barcode scanning, encrypted backup, and PIN authentication.
- Android camera barcode scanning (no ML Kit dependency, no camera permission).
- Database encryption at rest (only backups are encrypted).

## Technology

| Concern | Choice |
|---|---|
| Framework | Flutter 3.47 / Dart 3.13 |
| Architecture | Clean Architecture, feature-first |
| State | Riverpod |
| Navigation | GoRouter |
| Database | SQLite via Drift |
| Charts | fl_chart |
| Localisation | Flutter `gen-l10n` (ARB) |
| Crypto | `cryptography` (AES-256-GCM, Argon2id) |
| Printing | `esc_pos_utils_plus`, `pdf`, `printing` |
| Desktop window | `window_manager` |

## Quick start

```sh
export PATH="/opt/flutter-sdk/flutter/bin:$PATH"
export ANDROID_HOME=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

flutter pub get
dart run build_runner build
flutter gen-l10n
flutter run
```

Full instructions, including Windows and release builds, are in
[`docs/installation.md`](docs/installation.md).

## Build commands

```sh
flutter build apk --debug                # Android debug
flutter build apk --release              # Android release (configure signing first)
flutter build appbundle --release        # Play Store bundle
flutter build windows --release          # Windows (on a Windows host)
flutter build linux --release            # Linux (verified: see docs/known_limitations.md)
```

Before any release build, make sure Flutter's native-assets feature is on —
SQLite reaches Android as a Dart native asset, and with the feature off the APK
silently ships without `libsqlite3.so`:

```sh
flutter config --enable-native-assets
scripts/verify_apk_native_libs.sh build/app/outputs/flutter-apk/app-release.apk
```

## Verification status

The whole test suite passes (435 tests), `flutter analyze` is clean, and release
builds have been produced for **Android** and **Linux**. The **Windows** application
is configured but has not been built, because no Windows host or cross-compiler is
available. No hardware has been tested.

The Android release APK is published on the
[releases page](https://github.com/alifaleh302-dev/storeflow-pos/releases) and is
also produced at `build/app/outputs/flutter-apk/app-release.apk` by
`flutter build apk --release`. Always run
`scripts/verify_apk_native_libs.sh` on it before distributing: the `v1.0.0` APK was
built without SQLite in it and crashed on the first database call. `v1.0.1` fixes
that. See [`docs/installation.md`](docs/installation.md).

Read [`docs/known_limitations.md`](docs/known_limitations.md) before relying on any
unverified feature. The APK has never been launched on a device.

## Test commands

```sh
flutter analyze                          # static analysis
flutter test                             # all 435 tests
flutter test test/unit                   # arithmetic core
flutter test test/integration            # database, constraints, transactions
flutter test test/widget                 # router, shell, localisation, dashboard
```

## Documentation

| Document | Contents |
|---|---|
| [`docs/environment_report.md`](docs/environment_report.md) | What was inspected, what builds, what does not, and the failures that were fixed |
| [`docs/development_progress.md`](docs/development_progress.md) | Phase-by-phase status, what is tested, what is not, known issues, next steps |
| [`docs/architecture.md`](docs/architecture.md) | Layers, dependency direction, state, navigation, adaptive layout |
| [`docs/database.md`](docs/database.md) | Schema, tables, indexes, migrations, storage conventions |
| [`docs/business_rules.md`](docs/business_rules.md) | Money, quantities, exchange rates, costing, profit, inventory, cash, debts |
| [`docs/testing.md`](docs/testing.md) | Test architecture, coverage, and the gaps that exist |
| [`docs/hardware_compatibility.md`](docs/hardware_compatibility.md) | Printer and scanner plan, and the fact that no hardware has been tested |
| [`docs/installation.md`](docs/installation.md) | Install, build, run, troubleshoot |

## Verified platform status

| Target | Status |
|---|---|
| Android | **Release APK builds, bundles `libsqlite3.so` for every ABI, verified by script.** Not run on a device (none available). |
| Windows | **Configured, not built.** Requires a Windows host with Visual Studio. |
| Linux | Builds and runs; development and visual QA only, not shipped. |
| Tests | 435 passing on the Dart VM. |
| Static analysis | Clean. |

Screenshots from the running application are in
[`docs/screenshots/`](docs/screenshots/).

## Scope

The first release targets **one store, one active user, one local database**.

Deliberately postponed: multiple branches, cloud sync, multi-device operation, a
web dashboard, an online store, advanced multi-user permissions, general
accounting and AI sales forecasting. The schema and the layering leave room for
each of them; see the "Extension points" section of `docs/architecture.md`.

## Licence

Not yet chosen. The bundled Tajawal font is licensed under the SIL Open Font
License; its licence text is in `assets/fonts/OFL.txt`.
