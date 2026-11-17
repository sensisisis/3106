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

echo 'Checking native orbit with normal motion'
xcrun simctl launch "$DEVICE" "$BUNDLE" --simulate-installed-design
sleep 3
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/installed-four-modules.png"
sleep 0.4
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/activity-orbit-next-frame.png"
xcrun simctl terminate "$DEVICE" "$BUNDLE"

echo 'Checking that Reduce Motion still has a moving perimeter'
xcrun simctl launch "$DEVICE" "$BUNDLE" --simulate-installed-design --simulate-orbit-reduce-motion
sleep 2
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/reduced-motion-first.png"
sleep 0.4
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/reduced-motion-next.png"
echo 'Recording the real native orbit with Reduce Motion enabled'
python3 - "$DEVICE" "$OUTPUT" <<'PY'
import os,signal,subprocess,sys,time
from pathlib import Path
device,output=sys.argv[1:]
output=Path(output)
video=output/'activity-silver-orbit.mp4'
with (output/'recording.log').open('w') as log:
    process=subprocess.Popen(
        ['xcrun','simctl','io',device,'recordVideo','--codec=h264',str(video)],
        stdout=log,stderr=subprocess.STDOUT,start_new_session=True
    )
    try:
        time.sleep(7)
        if process.poll() is None:
            os.killpg(process.pid,signal.SIGINT)
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL)
            process.wait(timeout=5)
        video.unlink(missing_ok=True)
        log.write('\nVideo finalization timed out; screenshots remain valid.\n')
        print('NOTE: optional video timed out; continuing movement checks')
PY

echo 'Checking orbit resumes when returning from another app'
xcrun simctl launch "$DEVICE" com.apple.Preferences
sleep 1
xcrun simctl launch "$DEVICE" "$BUNDLE"
sleep 1
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/resumed-motion-first.png"
sleep 0.4
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/resumed-motion-next.png"
xcrun simctl terminate "$DEVICE" "$BUNDLE"
echo 'Capturing single-row design'
xcrun simctl launch "$DEVICE" "$BUNDLE" --simulate-installed-design --simulate-installed-single
sleep 2
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/installed-single-module.png"
swift "$ROOT/Tests/check_orbit_frames.swift" "$OUTPUT"

echo 'Capturing Fax Aura settings using real simulator device information'
xcrun simctl terminate "$DEVICE" "$BUNDLE"
xcrun simctl launch "$DEVICE" "$BUNDLE" --simulate-installed-design --simulate-settings
sleep 3
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/fax-aura-settings.png"
xcrun simctl terminate "$DEVICE" "$BUNDLE"

echo 'Capturing the unauthenticated Fax Aura login without onboarding'
xcrun simctl launch "$DEVICE" "$BUNDLE" --simulate-login-design
sleep 3
xcrun simctl io "$DEVICE" screenshot "$OUTPUT/fax-aura-login.png"
