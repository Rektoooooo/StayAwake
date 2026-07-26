#!/bin/sh
# Package StayAwake.app into a signed, notarised DMG for release.
#
# Notarisation needs credentials stored once:
#   xcrun notarytool store-credentials notary \
#     --apple-id <your-apple-id> --team-id <team-id> --password <app-specific-password>
#
# App-specific passwords come from appleid.apple.com, not your Apple ID password.
# Without a stored profile this still builds a signed DMG, but users will hit a
# Gatekeeper warning, so it says so and stops.
#
# The app and the DMG are notarised separately, on purpose. Stapling only the
# DMG leaves the copy dragged into /Applications without a ticket of its own, so
# Gatekeeper has to ask Apple over the network the first time it runs, and a
# first launch while offline can fail. Stapling the app makes it self-contained.
set -e
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-notary}"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG="StayAwake-$VERSION.dmg"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')}"

if [ -z "$IDENTITY" ]; then
	echo "No Developer ID certificate, so nothing can be notarised." >&2
	exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
	echo "No '$PROFILE' notarisation credentials. See the header of this script." >&2
	exit 1
fi

# Pass 1: the app itself, submitted as a zip because notarytool will not take
# a bare bundle.
echo "==> Notarising the app"
ZIP=$(mktemp -d)/StayAwake.zip
ditto -c -k --keepParent StayAwake.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple StayAwake.app
rm -f "$ZIP"

# Pass 2: the disk image built around the now-stapled app.
echo "==> Building and notarising the disk image"
STAGE=$(mktemp -d)
cp -R StayAwake.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "StayAwake" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

xcrun stapler validate StayAwake.app
xcrun stapler validate "$DMG"
echo "Built, signed, notarised and stapled: $(pwd)/$DMG"
