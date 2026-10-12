# Unified model preparation implementation plan

Goal: Prepare the Turbo model and its optional prompt enhancement from one inspector, with guided HF downloads and APP-owned inference configuration.

Architecture: One primary model card and two inline enhancement repository cards share folder selection, download progress, Hugging Face links and copyable CLI commands. Enhancement stays enabled by default; disabling it removes PE directory requirements. Selected folders resolve official GGUF, system_prompt.txt and vision projector files. Inference config is a bundled MPS Turbo resource copied to every case before the bridge starts.

Tech stack: SwiftUI, AppKit folder panels, Swift Codable core, cancellable hf CLI subprocess groups, bundled JSON, existing Python bridge.

1. Core resources: add the three repository identities and command construction; resolve PE files from folders with missing-file/ambiguous-file validation; preserve per-run explicit file snapshots internally.
2. HF downloads: use the hf executable beside the selected Python; download repositories to workspace/models, stream bounded progress/logs, cancel the subprocess group, retain partial downloads for HF resume, and validate before accepting paths. Do not install dependencies silently.
3. Configuration: bundle the known working eight-step MPS JSON. Remove editable Config UI and source-config dependence; write config.json in each case before submitting either PE or inference.
4. App state: model preparation drafts include main/T2I/I2I folders; one Save/Undo pair, enhancement toggle inline, missing resources focus the same preparation panel. Keep start-up model selection empty, environment probes separate, random seeds, reference order and streaming behavior.
5. UI: three compact cards in the right inspector, clear primary/optional hierarchy, icons inside path bars, download and help actions below. Fixed progress slots; download details in a popover rather than a new settings page. Slightly widen inspector for legible repository labels. No PE settings sheet.
6. Verification in a fresh isolated work directory: core folder resolution/config snapshot, mock hf success/failure/cancel/retry and arguments, production AppStore save/off/missing-resource/termination, native render/interaction/layout, existing bridge and lifecycle checks. Use actual official repository metadata and a small-file CLI download to verify command integration; reuse local weights read-only for real T2I/I2I if source/weights are available.
7. Commit and push main; wait for matching CI release and verify actual ZIP digest and commit before sending download/build links.
