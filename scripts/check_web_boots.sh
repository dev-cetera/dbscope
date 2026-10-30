#!/usr/bin/env bash
# Loads the web app in headless Chrome and fails if it throws during startup. Usage: bash scripts/check_web_boots.sh <url>
#
# A blank page is how a startup exception looks on web (the build compiles
# fine, then main() throws before the first frame), so `flutter build web`
# passing proves nothing. This catches it: any "Uncaught" console error in
# the first 20 s of virtual time fails, as does the app never starting.
# Read-only. Uses $CHROME, else google-chrome / chromium / the macOS app.
set -euo pipefail

url="${1:?usage: check_web_boots.sh <url>}"

chrome="${CHROME:-}"
if [ -z "$chrome" ]; then
  for c in google-chrome google-chrome-stable chromium chromium-browser \
           "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then chrome="$c"; break; fi
  done
fi
[ -n "$chrome" ] || { echo "check_web_boots: no Chrome found (set CHROME)" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$chrome" --headless=new --disable-gpu --no-first-run --no-sandbox \
  --user-data-dir="$tmp/profile" --enable-logging=stderr --v=0 \
  --virtual-time-budget=20000 --dump-dom "$url" >"$tmp/dom.html" 2>"$tmp/chrome.log" || true

console="$(grep 'CONSOLE' "$tmp/chrome.log" || true)"

if printf '%s\n' "$console" | grep -q 'Uncaught'; then
  echo "FAIL: $url threw during startup:"
  printf '%s\n' "$console" | grep -A2 'Uncaught' | cut -c1-300 | head -n 10
  exit 1
fi
if ! grep -q '<flt-glass-pane' "$tmp/dom.html"; then
  echo "FAIL: $url never started the Flutter engine (no <flt-glass-pane> in the DOM)."
  printf '%s\n' "$console" | cut -c1-300 | tail -n 10
  exit 1
fi
echo "OK: $url started with no uncaught errors."
