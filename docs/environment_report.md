# Environment Report — Phase 0

Inspected on 2026-11-03 inside a Debian 13 container. Every command below was
executed; nothing in this document is assumed.

## Host

| Item | Value | How it was checked |
|---|---|---|
| OS | Debian 13 (trixie), x86_64 | `cat /etc/os-release`, `uname -m` |
| Kernel | Linux 6.8.0-1055-gke | `uname -r` |
| Shell | bash | `echo $SHELL` |
| Privileges | `sudo` available, passwordless | `sudo -n true` |
| Network | Working (pub.dev, dl.google.com reachable) | `flutter pub get`, `sdkmanager` |

## Toolchain

| Component | Version | Path | Status |
|---|---|---|---|
| Flutter | 3.47.9 (stable) | `/opt/flutter-sdk/flutter` | Installed |
| Dart | 3.13.7 | bundled with Flutter | Installed |
| JDK | 21 (`java-21-openjdk-amd64`) | `/usr/lib/jvm/java-21-openjdk-amd64` | Installed |
| Android SDK | cmdline-tools, platform-tools, build-tools | `/opt/android-sdk` | Installed |
| Android platforms | android-34, android-35, android-36 | `/opt/android-sdk/platforms` | Installed |
| Android NDK | 28.2.13676358 | `/opt/android-sdk/ndk` | Installed |
| CMake | 3.22.1 (Android), 3.31 (system) | `/opt/android-sdk/cmake`, `/usr/bin/cmake` | Installed |
| Ninja | present | `/opt/android-sdk/cmake/3.22.1/bin/ninja` | Installed |
| Clang / pkg-config | present | system | Installed |
| GTK 3 dev headers | present | system | Installed |
| libsecret-1 | 0.21.7 | system | Installed |
| Git | present | system | Installed |

`flutter doctor -v` reports no blocking issues for the Android toolchain.

## Environment variables

Written to `~/.profile` so they survive a new shell:

```sh
export PATH="/opt/flutter-sdk/flutter/bin:$PATH"
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

## Packages added for development and QA

Installed with `apt-get`: `inotify-tools`, `ripgrep`, `xvfb`, `x11-apps`,
`x11-utils`, `xdotool`, `imagemagick`, `tesseract-ocr`, `sqlite3`.

`xvfb` plus `xdotool` and `imagemagick` are used only for headless visual
inspection of the Linux desktop build (see `scripts/capture_screenshots.sh`).

## Platform capability — measured, not assumed

| Target | Capability in this environment | Evidence |
|---|---|---|
| Android | **Build verified.** Debug APK produced. | `flutter build apk --debug` → `build/app/outputs/flutter-apk/app-debug.apk` (178 MB) |
| Windows | **Not buildable here.** | Requires a Windows host with Visual Studio; `windows/` is configured but cannot be compiled on Linux |
| Linux (desktop) | **Build verified**, used for visual QA only | `flutter build linux --debug` → `build/linux/x64/debug/bundle/storeflow_pos` |
| Shared Dart code | Verified by tests on the Dart VM | `flutter test` → 97 passing |

The specification's Linux note applies: Android and the shared Dart code are
developed and verified here, but **Windows compilation has not been executed and
is not claimed as verified.** The Windows target is generated and configured;
building it requires a Windows environment with Visual Studio and the
"Desktop development with C++" workload:

```powershell
flutter config --enable-windows-desktop
flutter build windows --release
```

## Issues found and resolved

### 1. `local_http_server` does not exist

An early dependency list referenced a package that is not published on pub.dev.
Version solving failed. Resolved by removing it; no code depended on it. The
backup and restore design uses the filesystem directly, so no HTTP server is
needed.

### 2. Android build failed: NDK 28 removed the `armeabi` ABI

`flutter build apk --debug` failed inside the `jni` plugin:

```
CMake Error at .../android-legacy.toolchain.cmake:165 (message):
  armeabi is no longer supported.  Use armeabi-v7a.
```

Reproduced directly with the same CMake arguments Gradle used. The cause is a
transitive dependency chain:

```
path_provider (our dependency)
  -> path_provider_android 2.3.0+
       -> jni 1.1.1
            -> builds for the removed armeabi ABI
```

**Resolution:** pin `path_provider_android` to `2.2.23`, the last release before
the `jni` dependency was introduced (confirmed against the pub.dev API: 2.2.23
lists only `flutter` and `path_provider_platform_interface`; 2.3.0 adds `jni`
and `jni_flutter`). No shipped architecture is disabled by this pin. The pin and
its reasoning are recorded in `pubspec.yaml`.

### 3. Missing Android platform 34

A plugin declares `compileSdk` 34. Installed `platforms;android-34` and
`platforms;android-35` with `sdkmanager`.

### 4. Linux build: missing `libsecret-1`

`flutter_secure_storage_linux` requires `libsecret-1 >= 0.18.4`. Installed
`libsecret-1-dev`.

### 5. Linux build: stale CMake cache pointed install prefix at `/usr/local`

A CMake configure run performed before the platform toolchain was complete left
`CMAKE_INSTALL_PREFIX=/usr/local` in `build/linux/x64/debug/CMakeCache.txt`,
causing `Permission denied` on install. Resolved by deleting `build/linux` so
CMake re-evaluates `CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT`. This is a
build-directory artefact, not a project defect; a clean build is unaffected.

## Missing dependencies and remaining requirements

| Requirement | Status |
|---|---|
| Windows SDK / Visual Studio | **Missing.** Required to build or verify the Windows target. |
| Android device or emulator | **Missing.** No hardware to run the APK on, so no runtime Android verification. |
| Physical ESC/POS printer | **Missing.** Printing is implemented behind adapters; no hardware verification possible. |
| Barcode scanner (USB HID) | **Missing.** Keyboard-wedge adapter implemented; no hardware verification possible. |
| Android camera | **Missing.** Camera scanning is implemented behind an adapter; untested without a device. |

## Commands that were run and their results

```sh
flutter --version                          # 3.47.9 / Dart 3.13.7
flutter doctor -v                          # no blocking issues for Android
flutter pub get                            # resolved (see issue 1)
dart run build_runner build                # 21 generated outputs
flutter gen-l10n                           # ar + en localisations generated
flutter analyze                            # No issues found!
flutter test                               # 97 tests passed
flutter build apk --debug                  # app-debug.apk produced
flutter build linux --debug                # storeflow_pos produced
```
