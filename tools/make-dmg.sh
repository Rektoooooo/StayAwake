#!/bin/sh
# Package StayAwake.app into a signed, notarised DMG for release.
#
# Notarisation needs credentials stored once:
#   xcrun notarytool store-credentials notary \
#     --apple-id <your-apple-id> --team-id PH3V9JYRDW --password <app-specific-password>
#
# App-specific passwords come from appleid.apple.com, not your Apple ID password.
# Without a stored profile this still builds a signed DMG, but users will hit a
# Gatekeeper warning, so it skips straight to a warning of its own.
set -e
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-notary}"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
STAGE=$(mktemp -d)
DMG="StayAwake-$VERSION.dmg"

cp -R StayAwake.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "StayAwake" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')}"

if [ -z "$IDENTITY" ]; then
	echo "No Developer ID certificate: $DMG is ad-hoc and cannot be notarised." >&2
	exit 0
fi

codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
	echo "Built and signed $DMG"
	echo "NOT notarised: no '$PROFILE' credentials. See the header of this script." >&2
	exit 0
fi

echo "Submitting to Apple for notarisation, this usually takes a few minutes..."
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Staple the ticket into the DMG so it validates without a network round trip.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "Built, signed, notarised and stapled: $(pwd)/$DMG"
