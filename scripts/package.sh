#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/LightX2V APP.app}"
ARCHIVE="${2:-$ROOT/dist/LightX2V-APP-macOS-arm64.zip}"

test -f "$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/LightX2VApp"
test -f "$APP/Contents/Resources/bridge.py"
test -f "$APP/Contents/Resources/prompt_enhancement.py"
test -s "$APP/Contents/Resources/requirements.txt"
test -s "$APP/Contents/Resources/qwen_image_21_turbo.json"
for archive in LightX2V-0.6.0-minimal.tar.gz llama-b11583-bin-macos-arm64.tar.gz; do
    cmp "$ROOT/Sources/LightX2VCore/Resources/Bundled/$archive" "$APP/Contents/Resources/Bundled/$archive"
done
test "$(lipo -archs "$APP/Contents/MacOS/LightX2VApp")" = arm64
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict "$APP"

# Package before uploading: preserve executable permissions and the .app bundle.
mkdir -p "$(dirname "$ARCHIVE")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

# Verify the downloadable archive, not only the app in the build directory.
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lightx2v-package.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
RESTORED_APP="$VERIFY_DIR/$(basename "$APP")"
test -x "$RESTORED_APP/Contents/MacOS/LightX2VApp"
codesign --verify --deep --strict "$RESTORED_APP"
cmp "$APP/Contents/MacOS/LightX2VApp" "$RESTORED_APP/Contents/MacOS/LightX2VApp"
for resource in bridge.py prompt_enhancement.py requirements.txt qwen_image_21_turbo.json; do
    cmp "$APP/Contents/Resources/$resource" "$RESTORED_APP/Contents/Resources/$resource"
done

for archive in LightX2V-0.6.0-minimal.tar.gz llama-b11583-bin-macos-arm64.tar.gz; do
    cmp "$APP/Contents/Resources/Bundled/$archive" "$RESTORED_APP/Contents/Resources/Bundled/$archive"
done

(
    cd "$(dirname "$ARCHIVE")"
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)
printf 'Packaged and verified: %s\n' "$ARCHIVE"
