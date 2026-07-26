#!/bin/sh
# Build and install to /Applications, then relaunch.
#
# /Applications rather than this build directory: the Claude Code hooks hard
# code the path to stayawake-claim, and a login item pointing into a working
# tree breaks the moment the folder moves.
set -e
cd "$(dirname "$0")/.."

./build.sh

pkill -f "StayAwake.app/Contents/MacOS/StayAwake" 2>/dev/null || true
# LaunchServices returns -600 if `open` races the process it just killed.
sleep 3

rm -rf /Applications/StayAwake.app
cp -R StayAwake.app /Applications/StayAwake.app

open /Applications/StayAwake.app
sleep 3
if ! pgrep -f "StayAwake.app/Contents/MacOS/StayAwake" >/dev/null; then
	sleep 2
	open /Applications/StayAwake.app
	sleep 3
fi

if pgrep -f "StayAwake.app/Contents/MacOS/StayAwake" >/dev/null; then
	echo "Installed and running: /Applications/StayAwake.app"
else
	echo "Installed but NOT running: open /Applications/StayAwake.app" >&2
	exit 1
fi
