#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${LIGHTX2V_BUILD_DIR:-$ROOT/.build}/prompt-editor-checks"
mkdir -p "$SCRATCH"
swiftc "$ROOT/Sources/LightX2VApp/Palette.swift" \
    "$ROOT/Sources/LightX2VApp/SubtleScroller.swift" \
    "$ROOT/Sources/LightX2VApp/EditingFocus.swift" \
    "$ROOT/Sources/LightX2VApp/InteractionFeedback.swift" \
    "$ROOT/Sources/LightX2VApp/PathInputField.swift" \
    "$ROOT/Sources/LightX2VApp/PromptEditor.swift" \
    "$ROOT/Sources/LightX2VApp/ImagePasteboard.swift" \
    "$ROOT/Tests/PromptEditorChecks/main.swift" \
    -o "$SCRATCH/PromptEditorChecks"
"$SCRATCH/PromptEditorChecks"
