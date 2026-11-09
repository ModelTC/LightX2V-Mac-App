#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/LightX2V.app}"
ARCHIVE="${2:-$ROOT/dist/LightX2V-APP-macOS-arm64.zip}"

compare_bundled_resources() {
    python3 - "$1" "$2" <<'PY'
import filecmp
import json
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
manifest = json.loads((source / 'manifest.json').read_text())
for name in ['manifest.json', *manifest]:
    if Path(name).name != name or not filecmp.cmp(source / name, destination / name, shallow=False):
        raise SystemExit('Bundled resource differs or is missing: ' + name)
PY
}

test -f "$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/LightX2VApp"
test -x "$APP/Contents/Helpers/LightX2VMaintenance"
test -f "$APP/Contents/Resources/bridge.py"
test -f "$APP/Contents/Resources/prompt_enhancement.py"
test -s "$APP/Contents/Resources/requirements.txt"
test -s "$APP/Contents/Resources/qwen_image_21_turbo.json"
test -s "$APP/Contents/Resources/qwen_image_21_turbo_int8.json"
test -s "$APP/Contents/Resources/qwen_image_21_turbo_int8_metal.json"
compare_bundled_resources "$ROOT/Sources/LightX2VCore/Resources/Bundled" "$APP/Contents/Resources/Bundled"
test "$(lipo -archs "$APP/Contents/MacOS/LightX2VApp")" = arm64
test "$(lipo -archs "$APP/Contents/Helpers/LightX2VMaintenance")" = arm64
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict "$APP/Contents/Helpers/LightX2VMaintenance"
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
cmp "$APP/Contents/Helpers/LightX2VMaintenance" "$RESTORED_APP/Contents/Helpers/LightX2VMaintenance"
cmp "$APP/Contents/Info.plist" "$RESTORED_APP/Contents/Info.plist"
for resource in bridge.py prompt_enhancement.py requirements.txt qwen_image_21_turbo.json qwen_image_21_turbo_int8.json qwen_image_21_turbo_int8_metal.json; do
    cmp "$APP/Contents/Resources/$resource" "$RESTORED_APP/Contents/Resources/$resource"
done

compare_bundled_resources "$APP/Contents/Resources/Bundled" "$RESTORED_APP/Contents/Resources/Bundled"

(
    cd "$(dirname "$ARCHIVE")"
    shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
)
printf 'Packaged and verified: %s\n' "$ARCHIVE"
