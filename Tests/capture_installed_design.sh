#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${INSTALLED_SCREENSHOT_DIR:-$ROOT/installed-design-preview}"
DERIVED="${RUNNER_TEMP:-/tmp}/InstalledDesignDerivedData"
mkdir -p "$OUTPUT"

RUNTIME=$(xcrun simctl list runtimes --json | python3 -c '
import json,sys
r=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
if not r: raise SystemExit("No available iOS simulator runtime")
r.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")))
print(r[-1]["identifier"])
')
DEVICE=$(xcrun simctl create "Installed Fax Aura UI" "com.apple.CoreSimulator.SimDeviceType.iPhone-11" "$RUNTIME")
cleanup() {
  xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
  xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Building Installed design for simulator $DEVICE ($RUNTIME)"
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcodebuild -project "$ROOT/ThreeOneOSSix.xcodeproj" -scheme 3106 \
  -configuration Debug -sdk iphonesimulator -destination "id=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > "$OUTPUT/simulator-build.log" 2>&1 || {
    tail -100 "$OUTPUT/simulator-build.log"
    exit 1
  }
APP="$DERIVED/Build/Products/Debug-iphonesimulator/3106.app"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl ui "$DEVICE" appearance dark
xcrun simctl status_bar "$DEVICE" override --time '7:45' \
  --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 69

echo 'Capturing four-row design with simulator-only visual fixtures'
xcrun simctl launch "$DEVICE" "$BUNDLE" --simulate-installed-design
sleep 5
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/installed-four-modules.png"
sleep 0.4
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/activity-orbit-next-frame.png"
xcrun simctl terminate "$DEVICE" "$BUNDLE"
echo 'Capturing single-row design matching the reported layout'
xcrun simctl launch "$DEVICE" "$BUNDLE" --simulate-installed-design --simulate-installed-single
sleep 3
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/installed-single-module.png"
python3 - "$OUTPUT" <<'PY'
import os,struct,sys
from pathlib import Path
p=Path(sys.argv[1])
for name in ['installed-four-modules.png','activity-orbit-next-frame.png','installed-single-module.png']:
    data=(p/name).read_bytes()
    assert data[:8]==b'\x89PNG\r\n\x1a\n'
    width,height=struct.unpack('>II',data[16:24])
    assert (width,height)==(828,1792),(name,width,height)
    print(f'PASS: {name}: {width}x{height}, {len(data)} bytes')
assert (p/'installed-four-modules.png').read_bytes() != (p/'activity-orbit-next-frame.png').read_bytes(), 'Animation frames did not change'
print('PASS: activity animation produces different real simulator frames')
PY
