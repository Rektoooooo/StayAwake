#!/bin/sh
# Builds StayAwake.app. No Xcode project: a few Swift files plus a bundle.
set -e
cd "$(dirname "$0")"

APP="StayAwake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

# Menu bar art. Regenerate from the masters with tools/make-icons.py.
cp Assets/*.png Assets/AppIcon.icns "$APP/Contents/Resources/"

# The menu bar app.
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/StayAwake" \
	Icon.swift Claims.swift Activity.swift Login.swift Setup.swift Power.swift Panel.swift SetupView.swift StayAwake.swift

# The hook helper Claude Code invokes. Shares ClaimStore with the app.
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/stayawake-claim" \
	Claims.swift ClaimTool.swift

# Ad-hoc signature keeps the bundle identity stable across rebuilds.
codesign --sign - --force "$APP"

echo "Built $(pwd)/$APP"
