#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product LightX2VApp
BIN="$(swift build --show-bin-path)"
SOURCES=()
for source in Sources/LightX2VApp/*.swift; do
    [[ "$source" == */LightX2VApp.swift ]] || SOURCES+=("$source")
done
swiftc -parse-as-library -I "$BIN/Modules" "${SOURCES[@]}" \
    "$BIN/LightX2VCore.build/"*.swift.o \
    "$BIN/LightX2VApp.build/DerivedSources/resource_bundle_accessor.swift" \
    Tests/AppStateChecks/*.swift -o "$BIN/AppStateChecks"
"$BIN/AppStateChecks" "$@"
