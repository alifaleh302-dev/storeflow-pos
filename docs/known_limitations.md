# Known limitations

This is an honest account of what StoreFlow POS does not do, or does not do
verified. It is written to be read before trusting the application with real
money, not after.

## Platform verification

The development environment is a Debian Linux container. That shapes what could be
verified and what could not.

| Target | Status | Evidence |
|---|---|---|
| Android | **Release APK built and verified** | `build/app/outputs/flutter-apk/app-release.apk`, 68.1 MB, bundles `libsqlite3.so` for arm64-v8a, armeabi-v7a and x86_64 |
| Linux desktop | **Release build succeeded** | `build/linux/x64/release/bundle/storeflow_pos`, 142 MB bundle |
| Windows desktop | Configured, **not built** | `windows/` target present; no Windows host or cross-compiler available |

The Linux release build compiles the whole shared codebase — all domain logic,
the database layer, the hardware adapters and the interface — so a compile error
anywhere would have failed it. It is real evidence that the code is sound.

The Android release APK was built here too, with JDK 21 and Android SDK 36, and its
signature verified with `apksigner`. What that proves is that the code compiles for
Android and packages correctly.

**The first published APK was not correct.** The `v1.0.0` release asset was built on
a machine with Flutter's native-assets feature switched off, so it shipped without
the SQLite native library and crashed at the first database call on a real device
(`Couldn't resolve native function 'sqlite3_initialize'`). The cause is recorded in
`installation.md`; `scripts/verify_apk_native_libs.sh` now inspects every shipped ABI
for the library and the symbol the FFI bindings need, and CI runs it on every build.

It is **not** evidence that the Windows application builds, which needs its own
toolchain and a Windows host. Nor has the APK been run on a real device or emulator:
it installs and starts as far as the packaging and signature are concerned, but no
one has watched it launch.

### Exact commands to finish the platform builds

On a Windows machine with Visual Studio 2022 and the Desktop development with C++
workload installed:

```bash
flutter config --enable-windows-desktop
flutter build windows --release
# Artifact: build/windows/x64/runner/Release/storeflow_pos.exe
```

The Android build needs no further work; see `installation.md` for the command and
the signing setup.

## Hardware

**No physical hardware was available.** No barcode scanner, no receipt printer, no
cash drawer was connected at any point during development.

What this means:

- The barcode scanner adapters and printer adapters are implemented behind abstract
  interfaces and covered by tests, including a real keyboard-wedge adapter that
  parses HID scanner input.
- A mock printer service is used in tests. It records what would have been printed
  rather than printing it.
- **No printer has ever produced a receipt.** No scanner has ever scanned a
  barcode. Compatibility with any specific device is unverified.
- The Arabic raster renderer for ESC/POS printers is tested by rendering to an image
  and checking that ink lands on the page, which proves it draws something. It does
  not prove a particular printer renders it correctly.

See `hardware_compatibility.md` for the device-by-device position.

## Security

- **The live database is not encrypted at rest.** Only backups are. Anyone who can
  read the database file can read the shop's data. Fixing this needs SQLCipher or
  equivalent, which is not in the dependency set.
- **No key recovery.** A forgotten backup password means the backup cannot be read.
  There is no back door.
- **The PIN guards the interface, not the file.** It stops someone using the
  application. It does not stop someone copying the database file and reading it
  elsewhere.
- **One user account.** The schema supports more without a migration, but
  multi-user permissions are not implemented and are not claimed.

## Interface

**Every feature screen except the dashboard is a placeholder.** The domain, data
and hardware-service layers are complete and tested, but the widgets that would
drive them are not written. Each of these routes builds and renders a message
saying the module is pending:

| Route | Screen state |
|---|---|
| `/` | **Dashboard — built**, reads real data |
| `/pos`, `/sales` | Placeholder |
| `/products`, `/products/new`, `/products/{id}` | Placeholder |
| `/inventory`, `/purchases`, `/suppliers` | Placeholder |
| `/customers`, `/expenses`, `/cash-register` | Placeholder |
| `/reports`, `/currencies`, `/backup`, `/settings` | Placeholder |

So the application **cannot yet ring up a sale, add a product, record a purchase,
take a payment, print a receipt, or make a backup from the interface.** The
services that would do all of that exist and pass their tests; nothing calls them.

This is verified by `test/widget/route_smoke_test.dart`, which boots the real
router against a real database and visits every route at phone and desktop
widths in Arabic and English, asserting that none of them throws. That proves the
navigation is sound; it does not make the screens functional.

Beyond that:

- The backup, restore and PIN **screens are not wired to their services.** The
  services are complete and tested; the interface to drive them is not finished.
- Arabic is the default language and the application runs right-to-left. Arabic
  text rendering has not been checked on a real device with real system fonts.
- The dashboard and report screens read from the reporting service. Their layout has
  not been reviewed on a small phone screen.
- **The Android APK has not been run.** It is built, signed and installable, but it
  has never been launched on a device or emulator, so nothing is known about how it
  behaves at runtime on Android.
- **Android camera barcode scanning is not implemented.** There is no ML Kit
  dependency, no camera permission in the manifest, and no platform channel. On
  Android the application falls back to manual barcode entry and the keyboard-wedge
  path. The abstract scanner interface is in place for a camera adapter to be added,
  but the adapter does not exist.

## Architecture deferrals

These are postponed by the specification and deliberately not built. The schema
leaves room for them, but no code exists:

- Multiple branches.
- Cloud synchronisation.
- Simultaneous multi-device operation.
- Web dashboard.
- Online store.
- Advanced general accounting.
- AI-based sales forecasting.

## Smaller gaps

- **No end-to-end integration test that drives the real user interface through a
  full sale.** The domain, data and hardware layers are tested thoroughly, and
  there is a widget test for the application shell, but no automated test taps
  through a checkout on screen.
- **No performance testing under load.** Indexes are in place for the searches that
  matter, and the code avoids loading the whole catalogue, but no benchmark was run
  against a catalogue of realistic size.
- **No migration from an older schema has been exercised.** The schema is at
  version 1 and the migration framework is in place, but there is no earlier version
  to migrate from yet.
