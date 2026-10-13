#!/bin/zsh
# Builds cDownloader.app in ./dist: the app, the browser helper, the command-line tool, the browser add-on and
# the video tools (yt-dlp, deno, ffmpeg). Then makes dist/cDownloader.dmg, the installer people drag into Applications.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "${0:A:h}/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product cDownloader
swift build -c "$CONFIG" --product cDownloaderHost
swift build -c "$CONFIG" --product cdownloader-cli
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/cDownloader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/cDownloader" "$APP/Contents/MacOS/cDownloader"
cp "$BIN/cDownloaderHost" "$APP/Contents/MacOS/cDownloaderHost"
cp "$BIN/cdownloader-cli" "$APP/Contents/Helpers/cdownloader"

# The video tools, so people install nothing else. They keep the signatures their makers gave them.
scripts/fetch-tools.sh "$APP/Contents/Helpers" "$APP/Contents/Resources/yt-dlp.version"
cp -R Resources/Licenses "$APP/Contents/Resources/Licenses"

# The browser add-on, without its test files.
mkdir -p "$APP/Contents/Resources/Extension"
rsync -a --exclude '*.test.js' --exclude 'package.json' --exclude 'node_modules' Extension/ "$APP/Contents/Resources/Extension/"

# Ad-hoc signature so macOS runs it locally (no Apple developer account needed).
codesign --force --sign - "$APP/Contents/MacOS/cDownloaderHost"
codesign --force --sign - "$APP/Contents/Helpers/cdownloader"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

# The installer: a disk image with the app, a shortcut to Applications, and a short note for the first open.
DMG="dist/cDownloader.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/cDownloader.app"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Installer/How to Install.txt" "$STAGE/"
rm -f "$DMG"
hdiutil create -quiet -volname cDownloader -srcfolder "$STAGE" -format UDZO "$DMG"
echo "Built $DMG"
