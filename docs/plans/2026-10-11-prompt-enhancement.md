# Prompt Enhancement Implementation Plan

**Goal:** Add optional local Qwen-Image-2.1 prompt enhancement, streamed thinking disclosure and a separate rewritten-prompt reply before automatic image generation.

**Architecture:** Extend each immutable generation request with an optional enhancement configuration; keep the original prompt in history. The Python bridge supervises llama.cpp and LightX2V sequentially, validates the complete enhancement JSON, saves its artifacts and emits bounded NDJSON updates. Swift renders the enhancement and image as two replies within the existing creation, with thinking collapsed by default.

**Tech Stack:** SwiftUI/AppKit, Swift Codable models, Python subprocess supervision, llama-completion / llama-mtmd-cli, existing LightX2V MPS bridge.

---

### Task 1: Resource configuration and persisted enhancement state
- Create `Sources/LightX2VCore/PromptEnhancement.swift` for configuration, local resource discovery, validation and result state.
- Modify `Sources/LightX2VCore/Models.swift` to persist optional request configuration and enhancement replies without changing the original prompt.
- Test defaults, configuration discovery, mode-specific requirements, encoding and interrupted-run recovery in `Tests/LightX2VCoreTests/EnhancementChecks.swift`.
- Run `swift run LightX2VCoreChecks`; expect all checks to pass.

### Task 2: Sequential supervised inference
- Create `Sources/LightX2VApp/Resources/prompt_enhancement.py`: exact script sampling/template settings, ordered multiple images, UTF-8 streaming, strict thinking/JSON parsing and result artifacts.
- Modify `Sources/LightX2VApp/Resources/bridge.py` to share cancellation/watchdog ownership across enhancement and image generation. Keep the off path unchanged. Explicit UI dimensions win; adaptive sizing uses validated enhancer ratio metadata.
- Test fragmented output, malformed/unfinished responses, nonzero exit, multiple/duplicate references, resource failure, off-path equivalence and cancellation in `Tests/test_prompt_enhancement.py`.
- Run `python -B -m unittest discover -s Tests -v`; expect all checks to pass, including child-process cleanup.

### Task 3: Model-page controls and two conversation replies
- Create `Sources/LightX2VApp/PromptEnhancementView.swift` with a restrained toggle, resource settings and collapsed thinking disclosure.
- Modify `Sources/LightX2VApp/AppStore.swift`, `GenerationParametersView.swift`, `Views.swift` and `Package.swift` to snapshot configuration, consume phase/result events and bundle the adapter.
- Batch streamed thinking updates; preserve stable preview dimensions, conversation grouping and bottom anchoring. Show original input, enhanced text, then the image reply. Failed enhancement must never fall back to image generation silently.
- Add AppState checks for toggle persistence, mode selection, original history, staged replies, failure/stop/relaunch, and layout while thinking or references change.

### Task 4: Local integration and release
- Run real T2I and I2I enhancement using the prepared local GGUF models; verify rewritten prompts reach LightX2V and image generation succeeds in an isolated test workspace.
- Inspect the built app with computer-use tools: toggle, resource configuration, hidden/expanded thinking, two replies, scrolling, repeat generations and cancellation.
- Run native editor/inspector checks and `bash scripts/build.sh` / `bash scripts/package.sh`.
- Commit and push to `main`; verify the exact commit's Actions checks and rolling `latest` package before delivery.

### Verification completed
- Core configuration, application state, streamed thinking layout, input/cursor/scrollbar and inspector checks passed.
- Model-resource checks run in the background; signed bundle resources remain unchanged at runtime. Reopened enhanced history and composer growth keep the image actions visible without manual scrolling.
- Python integration checks passed, including incomplete responses, duplicate references, cancellation and unchanged generation when disabled.
- Real local PE-T2I → LightX2V generated a 1248 × 832 image at the 1K tier; PE-I2I → LightX2V generated an 896 × 1184 image using the reference canvas.
- Real three-reference enhancement retained duplicate images; cancelling a real llama.cpp process reaped its children and never launched image inference.
