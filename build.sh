#!/bin/bash
# Builds "File Explorer.app" (release) next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="File Explorer.app"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/FileExplorer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FileExplorer"

# App icon, rendered by the app itself.
ICONSET="$(mktemp -d)/AppIcon.iconset"
"$BIN" --make-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>File Explorer</string>
    <key>CFBundleDisplayName</key><string>File Explorer</string>
    <key>CFBundleIdentifier</key><string>local.fileexplorer.app</string>
    <key>CFBundleExecutable</key><string>FileExplorer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>File Explorer shows and manages the files on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>File Explorer shows and manages the files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>File Explorer shows and manages the files in your Downloads folder.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>File Explorer shows and manages files on removable drives.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>File Explorer shows and manages files on network drives.</string>
    <key>NSAppleEventsUsageDescription</key><string>File Explorer asks Finder to empty the Recycle Bin.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $(pwd)/$APP"
