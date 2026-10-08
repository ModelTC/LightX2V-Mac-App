# LightX2V APP Implementation Plan

**Goal:** Deliver a native Apple Silicon macOS application for local Qwen-Image-2.1 text-to-image inference using the user's LightX2V checkout.

**Architecture:** SwiftUI manages a Codex-inspired workspace, settings and persistent generation history. A bundled standard-library Python supervisor launches the selected Python interpreter's `lightx2v.infer` module, streams newline-delimited JSON events, writes logs and controls cancellation. The source repository and model weights are external configurable dependencies.

**Tech Stack:** Swift 5.9 package, SwiftUI/AppKit, Foundation Process, Python 3.10+, existing PyTorch MPS environment. macOS 14+, arm64. No third-party app dependencies.

## Requirements

- Chinese interface; understated light workspace, sidebar history, central canvas/composer, optional inspector.
- Qwen-Image-2.1 / Viggle v0.3 only, fixed six-step schedule preserved exactly from supplied config.
- Editable prompt, dimensions, seed; random seed, regenerate, save image, reveal files, live logs, cancellation.
- Configurable repo, model, config, Python and output paths. A real environment check verifies MPS and import dependencies.
- One inference at a time, durable per-run request/config/log/result files, no remote inference or silent dependency installation.
- UI stays responsive. No fabricated progress. Crash-interrupted jobs recover as interrupted.

## ADR 001 — Native desktop shell

Choose SwiftUI over Electron (cross-platform, larger runtime) or a browser shell (fast iteration, less macOS integration). Native file dialogs, menus, keyboard shortcuts, drag export and an arm64 `.app` are useful for this local-only target. Cost: first release is macOS only.

## ADR 002 — Process isolation

Use a short-lived Python supervisor and separate inference process per request. It preserves the existing CLI and frees model memory after each run. Cost: reloads weights for every image. Use argv arrays, never interpolate prompts into shell commands. Terminate the child's process group and escalate after a grace period. Stop inference before app exit.

## ADR 003 — Reproducible local persistence

Copy the selected config to each unique run directory; persist request, manifest, full log and PNG there. Keep a small atomic history index in Application Support. Record actual seed and dimensions. Failed runs stay inspectable. Startup import / allocation checks run off the main thread. Missing paths and malformed configurations fail before GPU work.

## Implementation sequence

1. `Sources/LightX2VCore/Models.swift`: settings, validated request, history store, generation records. Verify request validation, seed persistence and interrupted-history recovery in `Tests/LightX2VCoreTests`.
2. `Sources/LightX2VApp/Resources/bridge.py`: validation, environment, preflight, argv, process supervision, logs, structured events. Verify CLI orientation, shell-metacharacter handling, success/failure/cancellation with an isolated fixture in `Tests/test_bridge.py`.
3. `Sources/LightX2VApp/AppStore.swift`: asynchronous process integration, checks, durable history, error recovery, export.
4. `Sources/LightX2VApp/Views.swift` and `LightX2VApp.swift`: workspace, inspector, settings, logs, keyboard commands and safe app exit.
5. `scripts/build.sh`: release build, icon, `.app` bundle, ad-hoc code signing. Build the application under `dist/` and exclude generated artifacts from Git.
6. Run `swift run LightX2VCoreChecks` (Command Line Tools has no XCTest module), Python integration tests, native UI inspection, and actual six-step MPS inference with the supplied local environment. Record test scope and measured result in README.

## Risks and handling

- 24 GiB unified memory: retain disk streaming and CPU offload. Default 1024 square; offer 512 for a quick test. Do not change allocator memory limits.
- Dependency mismatch: expose selected interpreter and check errors; do not install or alter the user's environment automatically.
- Cancellation during loading: process-group termination plus bounded forced shutdown; finished PNGs are accepted only after successful exit and decoding.
- Distribution: locally signed build is intended for this Mac; external distribution requires developer signing/notarization and a separately configured LightX2V environment.
