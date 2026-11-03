#!/usr/bin/env bash
# Captures desktop screenshots of the built Linux bundle under a virtual display.
#
# The Linux target exists for development and visual QA only: the shipped
# targets are Android and Windows. Running the app here proves the shared Dart
# code, the router, localisation and the database layer work on a desktop-class
# platform, and lets a reviewer inspect the real UI without a Windows machine.
#
# Usage: scripts/capture_screenshots.sh [app-binary] [output-dir]
set -u

APP="${1:-build/linux/x64/debug/bundle/storeflow_pos}"
OUT="${2:-docs/screenshots}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"
GEOMETRY="${GEOMETRY:-1280x800x24}"
DB="${DB:-$HOME/.local/share/com.storeflow.storeflow_pos/storeflow.sqlite}"

if [[ ! -x "$APP" ]]; then
  echo "Application binary not found or not executable: $APP" >&2
  echo "Build it first with: flutter build linux --debug" >&2
  exit 1
fi

mkdir -p "$OUT"
Xvfb ":${DISPLAY_NUM}" -screen 0 "$GEOMETRY" -nolisten tcp >/dev/null 2>&1 &
XVFB_PID=$!
export DISPLAY=":${DISPLAY_NUM}"

cleanup() {
  [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null
  kill "$XVFB_PID" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

# Wait for the X server to accept connections instead of sleeping a fixed time.
for _ in $(seq 1 50); do
  xdpyinfo -display ":${DISPLAY_NUM}" >/dev/null 2>&1 && break
  sleep 0.2
done

# Captures one screenshot for the given locale code and file name.
# The locale is written to the settings table so the running app reads it on
# start, exactly as a user switching language in Settings would.
capture_locale() {
  local locale="$1" name="$2"
  if [[ -f "$DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "UPDATE settings SET value='$locale' WHERE key='locale';"
  fi
  "$APP" >/dev/null 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 60); do
    xdotool search --name "StoreFlow" >/dev/null 2>&1 && break
    sleep 0.5
  done
  # Give the dashboard queries time to resolve so the capture shows figures
  # rather than the loading indicator.
  sleep 3
  # Capture the root window: the app window is centered and fills the virtual
  # screen, and capturing the root avoids races with window-mapping state.
  local attempt file
  file="$OUT/$name.png"
  for attempt in $(seq 1 20); do
    import -window root "$file" 2>/dev/null || true
    # A blank frame compresses to a few hundred bytes; real content is larger.
    if [[ -s "$file" ]] && (( $(stat -c%s "$file") > 10000 )); then break; fi
    sleep 0.5
  done
  if [[ -s "$file" ]]; then
    echo "wrote $file (locale=$locale, attempt=$attempt)"
  else
    echo "capture produced no usable image for locale=$locale" >&2
  fi
  kill "$APP_PID" 2>/dev/null
  wait "$APP_PID" 2>/dev/null
  APP_PID=""
}

capture_locale en 01-dashboard-en
capture_locale ar 02-dashboard-ar
