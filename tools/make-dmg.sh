#!/bin/sh
# Package StayAwake.app into a DMG for release.
#
# NOTE ON DISTRIBUTION: this produces an ad-hoc signed app. macOS quarantines
# anything downloaded from the internet, so users will hit "cannot be opened
# because the developer cannot be verified" and have to right-click -> Open,
# or run: xattr -dr com.apple.quarantine /Applications/StayAwake.app
#
# To avoid that you need an Apple Developer Program membership: sign with a
# Developer ID Application certificate, then notarize with notarytool and
# staple the ticket. See the README.
set -e
cd "$(dirname "$0")/.."

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
STAGE=$(mktemp -d)
DMG="StayAwake-$VERSION.dmg"

cp -R StayAwake.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
	-volname "StayAwake" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null

rm -rf "$STAGE"
echo "Built $(pwd)/$DMG"
echo "Unsigned: users must right-click -> Open on first launch."
