# Known limitations

This is an honest account of what StoreFlow POS does not do, or does not do
verified. It is written to be read before trusting the application with real
money, not after.

## Platform verification

The development environment is a Debian Linux container. That shapes what could be
verified and what could not.

| Target | Status | Evidence |
|---|---|---|
| Linux desktop | **Release build succeeded** | `build/linux/x64/release/bundle/storeflow_pos`, 142 MB bundle |
| Windows desktop | Configured, **not built** | `windows/` target present; no Windows host or cross-compiler available |
| Android | Configured, **not built** | `android/` target present; no Android SDK installed in this environment |

The Linux release build compiles the whole shared codebase — all domain logic,
the database layer, the hardware adapters and the interface — so a compile error
anywhere would have failed it. It is real evidence that the code is sound.

It is **not** evidence that the Android or Windows applications build. Those need
their own toolchains. The Windows and Android targets are configured and their
project files exist, but neither has been compiled here, and no claim is made that
they would compile without adjustment.

### Exact commands to finish the platform builds

On a Windows machine with Visual Studio 2022 and the Desktop development with C++
workload installed:

```bash
flutter config --enable-windows-desktop
flutter build windows --release
# Artifact: build/windows/x64/runner/Release/storeflow_pos.exe
```

On a machine with the Android SDK and a JDK:

```bash
flutter config --android-sdk <path-to-android-sdk>
flutter doctor --android-licenses
flutter build apk --release
# Artifact: build/app/outputs/flutter-apk/app-release.apk
```

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

- The backup, restore and PIN **screens are not wired to their services.** The
  services are complete and tested; the interface to drive them is not finished.
- Arabic is the default language and the application runs right-to-left. Arabic
  text rendering has not been checked on a real device with real system fonts.
- The dashboard and report screens read from the reporting service. Their layout has
  not been reviewed on a small phone screen.

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
