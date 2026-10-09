#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/LightX2V APP.app}"
SCRATCH="${LIGHTX2V_BUILD_DIR:-$ROOT/.build}"

swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c release --arch arm64 --product LightX2VApp
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c release --arch arm64 --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LightX2VApp" "$APP/Contents/MacOS/LightX2VApp"
# A .app uses the native Resources directory; SwiftPM's bundle remains a development fallback.
cp "$BIN/LightX2VAPP_LightX2VApp.bundle/"*.py "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleDisplayName</key><string>LightX2V APP</string>
<key>CFBundleName</key><string>LightX2V APP</string>
<key>CFBundleIdentifier</key><string>app.lightx2v.desktop</string>
<key>CFBundleExecutable</key><string>LightX2VApp</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSArchitecturePriority</key><array><string>arm64</string></array>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>LightX2V APP · Local image generation</string>
</dict></plist>
PLIST

ICON_WORK="$SCRATCH/icon"
mkdir -p "$ICON_WORK/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICON_WORK/master.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_WORK/master.png" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    twice=$((size * 2))
    sips -z "$twice" "$twice" "$ICON_WORK/master.png" --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
