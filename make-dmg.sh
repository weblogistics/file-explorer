#!/bin/bash
# Builds the app and packages it as "dist/File-Explorer.dmg" (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "File Explorer.app/Contents/Info.plist")
mkdir -p dist
DMG="dist/File-Explorer-$VERSION.dmg"
STAGE="$(mktemp -d)/File Explorer"
mkdir -p "$STAGE"
cp -R "File Explorer.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "File Explorer" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "Created: $(pwd)/$DMG"
