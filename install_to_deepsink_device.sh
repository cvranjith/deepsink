#!/bin/bash
# Weekly re-install of DeepSink to a physical iPhone over USB/Wi-Fi.
# Pulls latest from GitHub, builds for the connected device, installs, then
# cleans up build artifacts (but NOT the iOS platform/Simulator runtime: in
# this Xcode version that single package also provides the on-device
# build/deployment support, so deleting it breaks the next build and forces
# a ~17GB redownload). Ported line-for-line from yt-run's install_to_device.sh
# — same optimizations, same reasoning, just re-pointed at this project.
#
# Statelessness: everything this script needs lives in the repo (REPO_DIR)
# or gets pulled fresh into BUILD_DIR under /tmp, which is wiped clean both
# before and after every run. Nothing it produces is meant to survive
# between runs, and nothing it depends on lives outside git — so cloning
# this repo onto a different Mac (same Apple ID signed into Xcode, iOS
# platform support installed, phone paired once over USB — see README's
# "Fresh machine setup") and running this script should behave identically
# to running it here.
set -euo pipefail

REPO_DIR="/Users/ranjithcv/Documents/code/claude/deepsink"
PROJECT="$REPO_DIR/DeepSink/DeepSink.xcodeproj"
SCHEME="DeepSink"
# Built outside ~/Documents on purpose: that folder is synced by iCloud Drive
# (Desktop & Documents sync), which tags live build directories with Finder/
# file-provider metadata that codesign rejects ("resource fork, Finder
# information, or similar detritus not allowed"). Building in /tmp avoids it
# — same reasoning as yt-run's script, and this repo happens to sit under
# ~/Documents too, so the same fix applies here.
BUILD_DIR="/tmp/deepsink_build"

INFO_PLIST="$REPO_DIR/DeepSink/DeepSink/Info.plist"

echo "==> Pulling latest code"
cd "$REPO_DIR"
# Discard any stamp left in Info.plist by a previous run of this script
# (see the stamping step below) before pulling, so a dirty working tree
# never blocks/conflicts with a fast-forward.
git checkout -- DeepSink/DeepSink/Info.plist 2>/dev/null || true
git pull origin main

echo "==> Stamping build info into Info.plist"
# Read by BuildInfo.swift (via Bundle.main.infoDictionary) and shown on the
# Update App screen — a filesystem creation date is unusable for this
# (confirmed on yt-run: install/build tooling on both ends can leave the
# .app's own files, and even its container directory, reporting 1 Jan
# 1970), so this bakes the actual values into the bundle's content instead,
# immune to whatever metadata the packaging/install step does or doesn't
# preserve.
COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_DATE=$(git log -1 --format=%cI)
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for key in DSBuildCommitHash DSBuildCommitDate DSBuildInstallDate; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$INFO_PLIST" >/dev/null 2>&1 || true
done
/usr/libexec/PlistBuddy -c "Add :DSBuildCommitHash string $COMMIT_HASH" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :DSBuildCommitDate string $COMMIT_DATE" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :DSBuildInstallDate string $BUILD_DATE" "$INFO_PLIST"

echo "==> Finding connected device"
# Table output's "Identifier" column is annotated (e.g. "<uuid> (UDID)"), which
# breaks whitespace-based parsing. Use --json-output instead and pull the real
# UDID from properties.hardware.udid - that's what xcodebuild's -destination
# expects (the top-level "identifier" field is a different CoreDevice UUID).
DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" --omit-deprecated-fields-in-json >/dev/null
# Filters on `pairingState` ("paired"), not `connection.state`
# ("connected"/"disconnected"/etc.) — for a Wi-Fi-paired device, the latter
# is just a snapshot of whatever the tunnel happened to be doing the moment
# `list devices` ran, and idles to "disconnected" whenever nothing has used
# it in a while. `list devices` never re-establishes it either.
# `pairingState`, unlike that, reflects whether this Mac has a valid
# pairing record for the device at all — any *targeted* devicectl operation
# against a paired device's UDID (an actual build/install, same as the one
# below) transparently re-establishes the tunnel on demand.
DEVICE_ID=$(jq -r '[.result.devices[] | select(.properties.connection.pairingState == "paired")][0].properties.hardware.udid // empty' "$DEVICES_JSON")
if [ -z "$DEVICE_ID" ]; then
  echo "No paired device found. Plug in your iPhone via USB and unlock it, or pair it once over USB for future Wi-Fi use." >&2
  exit 1
fi
echo "Using device: $DEVICE_ID"

echo "==> Clearing cached provisioning profiles"
# Free (personal-team) provisioning profiles are only valid 7 days, and the
# app stops launching when its profile expires. Xcode's automatic signing
# *reuses* a cached profile as long as it still has any validity left, so a
# mid-week reinstall would inherit the original expiry instead of getting a
# fresh 7 days. Deleting the cache forces Xcode to mint a new profile on
# every run, resetting the clock. Harmless with a paid account (those
# profiles just get regenerated with their normal 1-year validity).
rm -f ~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision 2>/dev/null || true
rm -f ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision 2>/dev/null || true

echo "==> Building for device (no Simulator involved)"
# With the profile cache wiped above and two targets needing fresh profiles
# (DeepSink app + DeepSinkActivityExtension), -allowProvisioningUpdates
# sometimes races: a packaging step reads a profile UUID just as it's being
# superseded by the other target's resolution, and fails with "Build input
# file cannot be found" for a .mobileprovision that never ends up on disk.
# The actual profile download/registration still succeeds, so a second
# attempt (profiles now cached) reliably works - retry once before giving up.
build_attempt() {
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$BUILD_DIR" \
    -allowProvisioningUpdates
}

rm -rf "$BUILD_DIR"
if ! build_attempt; then
  echo "==> Build failed (likely a provisioning-profile resolution race after cache wipe); retrying once" >&2
  rm -rf "$BUILD_DIR"
  build_attempt
fi

APP_PATH=$(find "$BUILD_DIR/Build/Products" -maxdepth 2 -name "*.app" | head -1)
if [ -z "$APP_PATH" ]; then
  echo "Build succeeded but no .app bundle found under $BUILD_DIR/Build/Products" >&2
  exit 1
fi

echo "==> Installing $APP_PATH to device"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "==> Cleaning up build artifacts"
rm -rf "$BUILD_DIR"

echo "==> Done. App installed on device. (iOS platform left intact - required for future builds.)"
