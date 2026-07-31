#!/bin/sh
# Builds StayAwake.app. No Xcode project: a few Swift files plus a bundle.
#
# Signs with a Developer ID Application certificate when one is in the keychain,
# otherwise ad-hoc. Only a Developer ID build can be notarised, and only a
# notarised build opens without a Gatekeeper warning on someone else's Mac.
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
	Icon.swift Claims.swift Usage.swift Resume.swift Activity.swift Login.swift Setup.swift Power.swift Panel.swift SetupView.swift SettingsWindow.swift SettingsView.swift StayAwake.swift

# The hook helper Claude Code invokes. Shares ClaimStore with the app.
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/stayawake-claim" \
	Claims.swift Usage.swift ClaimTool.swift

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')}"

if [ -n "$IDENTITY" ]; then
	# Hardened runtime and a secure timestamp are both required by notarisation.
	# Nested code is signed before the bundle that contains it.
	codesign --force --timestamp --options runtime --sign "$IDENTITY" \
		"$APP/Contents/MacOS/stayawake-claim"
	codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
	echo "Signed with: $IDENTITY"
else
	codesign --force --sign - "$APP/Contents/MacOS/stayawake-claim"
	codesign --force --sign - "$APP"
	echo "Ad-hoc signed (no Developer ID certificate found)"
fi

codesign --verify --strict --deep "$APP"
echo "Built $(pwd)/$APP"
