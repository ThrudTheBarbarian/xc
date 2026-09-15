#!/bin/sh
# run.sh — the iOS run-loop spike, end to end in the simulator, unattended.
# Builds the .app bundle from SpikeLoop + Info.plist, boots an iPhone sim,
# installs, launches with the console attached, and greps the PASS sentinel
# the xtc side prints after three self-injected taps.
set -e
here=$(cd "$(dirname "$0")" && pwd)
[ -x "$here/SpikeLoop" ] || { echo "build SpikeLoop first (see README)"; exit 1; }
APP="$here/SpikeLoop.app"
rm -rf "$APP" && mkdir "$APP"
cp "$here/SpikeLoop" "$here/Info.plist" "$APP/"

UDID=$(xcrun simctl list devices available | grep -m1 "iPhone 16 Pro (" | grep -oE "[0-9A-F-]{36}")
[ -n "$UDID" ] || { echo "no iPhone 16 Pro simulator"; exit 1; }
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" >/dev/null
xcrun simctl install "$UDID" "$APP"
echo "== spike: launching (console attached) =="
out=$(xcrun simctl launch --console-pty "$UDID" com.compile-xc.spike-ios-loop 2>&1 | tee /dev/stderr) || true
echo "$out" | grep -q "^PASS" || { echo "== ios-loop spike: FAILED =="; exit 1; }
echo "== ios-loop spike: OK =="
