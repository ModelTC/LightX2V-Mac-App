#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${LIGHTX2V_BUILD_DIR:-$ROOT/.build}/inspector-checks"
mkdir -p "$SCRATCH"
swiftc "$ROOT/Sources/LightX2VApp/ClippedReveal.swift" \
    "$ROOT/Tests/InspectorChecks/main.swift" \
    -o "$SCRATCH/InspectorChecks"
"$SCRATCH/InspectorChecks"
