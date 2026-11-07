# Installation

StoreFlow POS is an offline application. It needs no server, no account and no
internet connection to run.

## Requirements

### To run a build

| Platform | Requirement |
|---|---|
| Android | Android 5.0 (API 21) or newer, 64-bit ARM recommended |
| Windows | Windows 10 or newer, 64-bit |
| Disk | The database is small; a shop with tens of thousands of products and several years of invoices stays in the low hundreds of megabytes |

### To build from source

| Tool | Version used | Notes |
|---|---|---|
| Flutter | 3.47.9 (stable) | `flutter --version` |
| Dart | 3.13.7 | bundled with Flutter |
| JDK | 21 | required for the Android build |
| Android SDK | platforms 34, 35, 36; build-tools; NDK 28.2.13676358 | NDK is required by a transitive plugin |
| Visual Studio 2022 | with "Desktop development with C++" | Windows builds only |
| Git | any recent version | |

**Flutter's native-assets feature must be on.** SQLite is shipped to Android as a
Dart native asset rather than as a platform plugin, so the build machine has to
bundle it:

```sh
flutter config --enable-native-assets
```

The feature is enabled by default on the stable channel. It is only a problem on a
machine where it was explicitly switched off — and the symptom is quiet: the APK
builds, installs and launches, then dies on the first database query with
`Couldn't resolve native function 'sqlite3_initialize'`. The
`scripts/verify_apk_native_libs.sh` check below catches it before shipping.

Linux and macOS are not shipped targets. A Linux desktop target exists in this
repository for development and headless visual QA; it is not a product deliverable.

## Getting the source and dependencies

```sh
git clone <repository-url> storeflow_pos
cd storeflow_pos

export PATH="/opt/flutter-sdk/flutter/bin:$PATH"     # adjust to your Flutter path
export ANDROID_HOME=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

flutter pub get
dart run build_runner build      # Drift database code
flutter gen-l10n                 # Arabic and English localisations
```

`build_runner` and `gen-l10n` must be re-run after changing a Drift table or an
`.arb` file. Generated files (`*.g.dart`, `lib/l10n/generated/`) are not edited
by hand.

## Running

### Android

```sh
flutter devices                  # confirm the device is visible
flutter run -d <device-id>
```

For a release build:

```sh
flutter config --enable-native-assets   # required, see "To build from source"
flutter build apk --release              # single APK
flutter build appbundle --release        # Play Store bundle
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

Then confirm the package actually contains the database engine:

```sh
scripts/verify_apk_native_libs.sh build/app/outputs/flutter-apk/app-release.apk
```

That script checks every shipped ABI for `libsqlite3.so` and for the
`sqlite3_initialize` entry point the Dart bindings look up. It is the cheap
guard against the "native library missing" crash described in Troubleshooting.

A release build must be signed with your own key before distribution. The
generated `android/app/build.gradle.kts` currently signs release builds with the
debug key so that `flutter run --release` works; **replace that with a real
signing config before publishing.**

### Windows

On a Windows machine with Visual Studio and the C++ workload installed:

```powershell
flutter config --enable-windows-desktop
flutter pub get
dart run build_runner build
flutter gen-l10n
flutter run -d windows
```

Release build:

```powershell
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\`

Distribute the whole folder, not just the `.exe`: the executable needs the
adjacent DLLs and the `data` directory.

> **This build has not been executed.** It requires a Windows host. See
> `environment_report.md`.

### Linux (development only)

```sh
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
flutter config --enable-linux-desktop
flutter build linux --debug
./build/linux/x64/debug/bundle/storeflow_pos
```

To capture screenshots without a display:

```sh
sudo apt-get install -y xvfb xdotool imagemagick
scripts/capture_screenshots.sh
```

## First run

On first launch the application creates its database, applies the schema and
seeds the defaults: a base currency, the built-in units, a walk-in customer,
expense categories and an owner user. This happens once; later launches reuse
the existing file.

Where the database lives:

| Platform | Location |
|---|---|
| Android | the app's private support directory, not readable by other apps |
| Windows | `%APPDATA%\<publisher>\storeflow_pos\` |
| Linux (dev) | `~/.local/share/com.storeflow.storeflow_pos/storeflow.sqlite` |

Deleting this file resets the application to a new store. **Back up before
doing that.**

## Verifying an installation

```sh
flutter analyze     # expect: No issues found!
flutter test        # expect: all tests passed
```

To confirm the database is healthy:

```sh
sqlite3 <path-to>/storeflow.sqlite "PRAGMA integrity_check; PRAGMA foreign_key_check;"
```

Both should report no problems.

## Troubleshooting

### `Couldn't resolve native function 'sqlite3_initialize'` on Android

The full message looks like this:

```
Invalid argument(s): Couldn't resolve native function 'sqlite3_initialize'
in 'package:sqlite3/src/ffi/libsqlite3.g.dart' : No asset with id
'package:sqlite3/src/ffi/libsqlite3.g.dart' found. No available native assets.
Attempted to fallback to process lookup. undefined symbol: sqlite3_initialize.
```

The APK was built without SQLite in it. Since package:sqlite3 3.x, SQLite is a
Dart **native asset**: it is compiled and bundled by the build hooks, not by a
platform plugin. If the build machine has the native-assets feature switched off,
the APK still builds, installs and launches — it simply has no `libsqlite3.so`,
and the crash arrives at the first database call.

`sqlite3_flutter_libs` does not fix this. From version 0.6.0 that package is an
empty no-op; it exists only so that apps migrating to sqlite3 3.x cannot
accidentally keep the old 0.5.x build scripts.

Fix: enable the feature and rebuild from clean.

```sh
flutter config --enable-native-assets
flutter clean
flutter pub get
flutter build apk --release
scripts/verify_apk_native_libs.sh build/app/outputs/flutter-apk/app-release.apk
```

The script must report that every shipped ABI contains `libsqlite3.so`. If it
does, the rebuilt APK starts normally.

### `Package(s) ... require the dart assets feature to be enabled` during the build

The same cause as above, caught earlier. On some Flutter versions the build stops
with this message instead of producing a broken APK:

```
Package(s) cnativeapi objective_c sqlite3 require the dart assets feature to be
enabled. Enable code assets using `flutter config --enable-native-assets`.
```

Run `flutter config --enable-native-assets` and build again.

### `armeabi is no longer supported` during the Android build

A transitive dependency pulled in a plugin that still targets the removed
`armeabi` ABI. `pubspec.yaml` pins `path_provider_android` to `2.2.23` for
exactly this reason. If you have changed that pin, restore it.

### `libsecret-1` not found during the Linux build

```sh
sudo apt-get install -y libsecret-1-dev
```

### `Permission denied` writing to `/usr/local` during the Linux build

A stale CMake cache holds an install prefix from an earlier configure. Remove
the build directory and rebuild:

```sh
rm -rf build/linux && flutter build linux --debug
```

### Missing Android platform

```sh
sdkmanager --install "platforms;android-34" "platforms;android-35"
```

### Missing Android NDK

```sh
sdkmanager --install "ndk;28.2.13676358"
```

### Generated code out of date after a schema change

```sh
dart run build_runner build
```

If that reports conflicts:

```sh
dart run build_runner clean && dart run build_runner build
```

### `flutter gen-l10n` warns about `synthetic-package`

That option was removed from Flutter and has been deleted from `l10n.yaml`. If
the warning reappears, check that the file does not contain it.

## Android release build — verified

The Android release APK has been built and verified in this environment.

```bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

flutter config --enable-native-assets
flutter pub get
flutter build apk --release
# Artifact: build/app/outputs/flutter-apk/app-release.apk

scripts/verify_apk_native_libs.sh build/app/outputs/flutter-apk/app-release.apk
# expect: OK for arm64-v8a, armeabi-v7a and x86_64
```

| Property | Value |
|---|---|
| Application ID | `com.storeflow.storeflow_pos` |
| Version | `1.0.0` (versionCode 1) |
| minSdk / targetSdk / compileSdk | 24 / 36 / 36 |
| Architectures | arm64-v8a, armeabi-v7a, x86_64 |
| Native libraries | `libsqlite3.so` bundled for every ABI |
| Size | 68.1 MB |
| Signature | APK Signature Scheme v2, release keystore |
| Debuggable | no |

The toolchain used: JDK 21, Android SDK 36.1.0, build-tools 36.1.0, NDK 28.2.13676358,
Gradle 9.3.1, AGP 9.1.0.

### The 1.0.0 release artifact was broken

The APK published as `v1.0.0` was built on a machine with the native-assets
feature switched off. It installs and launches, then fails at the first database
call with `Couldn't resolve native function 'sqlite3_initialize'` — see
Troubleshooting. Inspecting that artifact shows the cause directly: it contains
`libapp.so` and `libflutter.so` for each ABI and no `libsqlite3.so` at all.

The rebuild above fixes it, and `scripts/verify_apk_native_libs.sh` now fails the
build if the library goes missing again.

### Signing

The release build reads `android/key.properties`, which is **not** committed:

```properties
storePassword=<password>
keyPassword=<password>
keyAlias=storeflow
storeFile=/absolute/path/to/storeflow-release.jks
```

Create the keystore once and keep it safe — an application update must be signed
with the same key or Android will refuse to install it:

```bash
keytool -genkeypair -v \
  -keystore storeflow-release.jks -storetype PKCS12 \
  -keyalg RSA -keysize 4096 -validity 10950 \
  -alias storeflow -storepass <password> -keypass <password> \
  -dname "CN=StoreFlow POS, O=StoreFlow, C=EG"
```

When `android/key.properties` is absent the release build falls back to the debug
keys so `flutter run --release` still works on a fresh checkout. A build made that
way is **not** suitable for distribution.
