#!/usr/bin/env bash
# Verifies that an Android APK is fit to ship: that it contains the native
# libraries the application needs at runtime, and (optionally) that it is
# signed with a real release key rather than the debug key.
#
# Why this exists: package:sqlite3 3.x delivers SQLite as a Dart *native asset*,
# not as a platform plugin. If the build machine has Flutter's native-assets
# feature switched off, `flutter build apk` can still produce an APK that
# installs and launches — it just has no libsqlite3.so in it. The failure only
# appears on a device, at the first query, as
#
#   Couldn't resolve native function 'sqlite3_initialize'
#
# Nothing in `flutter analyze` or `flutter test` catches that, because the tests
# run on a host that has a system SQLite. This script is the cheap check that
# closes the gap.
#
# Usage:
#   scripts/verify_apk_native_libs.sh [path-to.apk] [--require-release-signature]
#
# Without --require-release-signature the signature is only reported, because a
# local `flutter build apk --release` with no keystore is legitimately
# debug-signed. Publishing pipelines should pass the flag.
set -euo pipefail

APK=""
REQUIRE_RELEASE_SIGNATURE=0
for arg in "$@"; do
  case "$arg" in
    --require-release-signature) REQUIRE_RELEASE_SIGNATURE=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) APK="$arg" ;;
  esac
done
APK="${APK:-build/app/outputs/flutter-apk/app-release.apk}"
REQUIRED_LIB="libsqlite3.so"
REQUIRED_SYMBOL="sqlite3_initialize"

if [[ ! -f "$APK" ]]; then
  echo "APK not found: $APK" >&2
  echo "Build it first with: flutter build apk --release" >&2
  exit 1
fi

echo "Verifying $APK"

if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required to inspect the APK" >&2
  exit 1
fi

# List the ABIs the APK ships, and the shared objects inside each.
entries="$(unzip -Z1 "$APK" | grep -E '^lib/[^/]+/[^/]+\.so$' || true)"

if [[ -z "$entries" ]]; then
  echo "FAIL: the APK contains no native libraries at all." >&2
  exit 1
fi

abis="$(printf '%s\n' "$entries" | cut -d/ -f2 | sort -u)"
status=0

for abi in $abis; do
  lib_path="lib/$abi/$REQUIRED_LIB"
  if ! printf '%s\n' "$entries" | grep -qx "$lib_path"; then
    echo "FAIL: $abi is missing $lib_path" >&2
    status=1
    continue
  fi

  # Presence in the zip is necessary but not sufficient: the library must also
  # export the entry point the Dart FFI bindings look up. Extract to a scratch
  # directory and read the dynamic symbol table.
  tmp="$(mktemp -d)"
  unzip -q -o "$APK" "$lib_path" -d "$tmp"
  extracted="$tmp/$lib_path"

  # Collect the dynamic symbol table once, trying nm then readelf. Both are
  # best-effort: under load either can fail transiently, and a failure here
  # must not turn into a false negative.
  symbols=""
  if command -v nm >/dev/null 2>&1; then
    symbols="$(nm -D --defined-only "$extracted" 2>/dev/null || true)"
  fi
  if [[ -z "$symbols" ]] && command -v readelf >/dev/null 2>&1; then
    # --wide matters: without it readelf truncates long symbol names to
    # something like "sqlite3_init[...]", which would never match.
    symbols="$(readelf --wide --dyn-syms "$extracted" 2>/dev/null || true)"
  fi

  if printf '%s' "$symbols" | grep -qw "$REQUIRED_SYMBOL"; then
    echo "OK:   $abi ships $lib_path exporting $REQUIRED_SYMBOL"
  elif grep -aq "$REQUIRED_SYMBOL" "$extracted"; then
    # No usable symbol table (no nm/readelf, or both failed): the name still
    # appears in the file's string table, which is where the dynamic loader
    # would find it. Weaker evidence, but it still catches a library that has
    # nothing to do with SQLite.
    echo "OK:   $abi ships $lib_path mentioning $REQUIRED_SYMBOL (symbol table unreadable; weak check)"
  else
    echo "FAIL: $abi $lib_path does not export $REQUIRED_SYMBOL" >&2
    status=1
  fi
  rm -rf "$tmp"
done

if (( status != 0 )); then
  cat >&2 <<'HINT'

The APK is missing the SQLite native library. This is a build-environment
problem, not a source problem. Rebuild with native assets enabled:

    flutter config --enable-native-assets
    flutter clean
    flutter build apk --release
HINT
  exit 1
fi

echo "All shipped ABIs contain $REQUIRED_LIB."

# Report, and optionally enforce, the signing certificate. A debug-signed APK
# cannot be published to a store and cannot be upgraded by a release-signed one,
# so the distinction matters — and it is invisible without inspecting the file.
apksigner=""
for candidate in \
  "${ANDROID_HOME:-}/build-tools/"*/apksigner \
  "${ANDROID_SDK_ROOT:-}/build-tools/"*/apksigner; do
  [[ -x "$candidate" ]] && apksigner="$candidate" && break
done
apksigner="${apksigner:-$(command -v apksigner || true)}"

if [[ -n "$apksigner" ]]; then
  signer_line="$("$apksigner" verify --print-certs "$APK" 2>/dev/null \
    | grep -i "signer #1 certificate DN" || true)"
  if [[ -n "$signer_line" ]]; then
    echo "Signature: ${signer_line#*: }"
    if [[ "$signer_line" == *"Android Debug"* ]]; then
      if (( REQUIRE_RELEASE_SIGNATURE )); then
        echo "FAIL: the APK is debug-signed, and a release signature was required." >&2
        echo "Provide android/key.properties and rebuild, or drop --require-release-signature." >&2
        exit 1
      fi
      echo "NOTE: debug-signed. Fine for testing, not for publishing."
    fi
  fi
else
  echo "NOTE: apksigner not found; signature not checked."
  if (( REQUIRE_RELEASE_SIGNATURE )); then
    echo "FAIL: --require-release-signature was given but apksigner is unavailable." >&2
    exit 1
  fi
fi

exit 0
