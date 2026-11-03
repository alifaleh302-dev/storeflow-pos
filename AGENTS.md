# StoreFlow POS — Repository Guide

Offline-first Point of Sale and inventory management system. Flutter, targeting
**Android** and **Windows**. Arabic is the default language.

## Build and test commands

```sh
export PATH="/opt/flutter-sdk/flutter/bin:$PATH"
export ANDROID_HOME=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

flutter pub get
dart run build_runner build      # after changing a Drift table
flutter gen-l10n                 # after changing an .arb file

flutter analyze                  # must stay clean
flutter test                     # 97 tests, must stay green
flutter build apk --debug
```

Never edit `lib/infrastructure/database/app_database.g.dart` or
`lib/l10n/generated/`; both are regenerated.

## Code generation

- **Drift** — `dart run build_runner build`. Re-run after editing
  `lib/infrastructure/database/tables.dart` or `app_database.dart`.
  `--delete-conflicting-outputs` was removed from this Flutter version and is
  ignored with a warning; do not pass it.
- **Localisation** — `flutter gen-l10n`. ARB sources are `lib/l10n/app_en.arb`
  (the template) and `lib/l10n/app_ar.arb`. **Both must have the same key set**;
  add the key to `app_en.arb` first, then mirror it in `app_ar.arb`.

## Non-negotiable rules

1. **Never use `double` for money.** Use `Money` (integer minor units plus the
   currency's decimal digits) from `lib/core/money/money.dart`.
2. **Never use floating point for quantities.** Use `Quantity`, scaled integers
   with a documented scale of 1000.
3. **Never delete a posted financial or inventory row.** Void it, or add a
   reversing document.
4. **Money and stock changes happen inside one transaction.** A document is
   never written without its inventory and payment records.
5. **The domain layer imports no Flutter, Drift, SQLite or plugin code.**
6. **No fabricated data in a page.** A module that is not implemented must say
   so; see `lib/shared/widgets/pending_module_view.dart` for the pattern.
7. **No mocks in the data path.** Tests use the real `AppDatabase` via
   `AppDatabase.memory()`. Only the storage location is swapped.
8. **Report honestly.** Never mark something verified unless the command that
   verifies it was actually run. Windows cannot be built in a Linux container;
   say so rather than claiming success.

## Environment quirks

- **`path_provider_android` is pinned to `2.2.23`** in `pubspec.yaml`. Versions
  2.3.0+ pull in `jni`, whose CMake build targets the `armeabi` ABI that NDK 28
  removed, failing the Android build. Do not lift the pin without re-testing the
  APK build.
- **`synthetic-package` was removed from `l10n.yaml`**; re-adding it produces a
  warning.
- **A stale `build/linux/.../CMakeCache.txt`** can hold an install prefix of
  `/usr/local` and fail with `Permission denied`. Fix: `rm -rf build/linux`.
- **Flutter 3.47 uses Riverpod 3**, where `StateProvider` was removed. Use
  `NotifierProvider` with an explicit setter instead.
- **`window_manager` 0.6** replaced the global `windowManager` helper with
  `WindowManager.instance.getCurrent()` returning a `Window`. Its `Size` type is
  nativeapi's, not Flutter's: convert with `.toNative()`.

## Architecture map

```
lib/app/                 shell, router, theme, providers
lib/core/money/          Money, ExchangeRate, Quantity, RoundingMode
lib/core/database/       SequenceService, SettingsService, AuditService
lib/infrastructure/database/  tables.dart, app_database.dart (+ .g.dart)
lib/features/<name>/     data | domain | presentation
lib/shared/              reusable widgets and dialogs
```

`databaseProvider` throws unless overridden. `lib/bootstrap.dart` overrides it
with the on-disk database; tests override it with `AppDatabase.memory()`.

## Key invariants to preserve

- Exchange rate direction: **`toBase` converts transaction currency → base
  currency**, and the rational is a function of both currencies' decimal digits.
  See `docs/business_rules.md` for worked examples.
- Reports read the stored `base_*` columns. They never recompute with today's
  rate.
- `product_stock` is a cache; `inventory_movements` is the source of truth. They
  must always reconcile.
- Account balances are the signed sum of ledger entries, never a stored total.

## Documentation to update after each phase

`docs/development_progress.md` (status, tests, known issues),
`docs/environment_report.md` (if the environment changes), and
`docs/database.md` (if the schema changes).

## Current status

Phases 0 and 1 complete. Phases 2–10 not started. Business modules (POS,
products, purchases, customers, suppliers, expenses, cash register, reports,
printing, scanning, backup) are **not implemented**; their pages state this on
screen. See `docs/development_progress.md`.
