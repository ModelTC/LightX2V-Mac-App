# Qwen-Image-2.1-Turbo implementation

Replace the only image model with Turbo. Use the upstream MPS configuration and native `qwen_image_21` entry point for both t2i and i2i. Do not retain Viggle inference, adapters, configuration fallback, or migration logic.

1. Centralize the Turbo display name, eight denoising steps and configuration path. Update selection, preparation, empty state, reply headers and progress indicators. Keep launch model selection empty.
2. Validate the checkpoint's eight saved sampling sigmas and matching MPS configuration, including disabled time shifting and CFG. Use `python -m lightx2v.infer` for text and reference images; remove the obsolete editing patch.
3. Suggest the Turbo config from the selected source and discover only Turbo weights near the configured directories. Preserve valid explicit paths. Keep Prompt Enhancement's separate T2I/I2I models and behavior.
4. Exercise config rejection, all size mappings, ordered/duplicate references, eight-step progress, cancellation, same-conversation generation, enhancement streaming and relaunch. Run the existing native UI and setup checks.
5. Run real Turbo t2i/i2i with enhancement off and on, plus fixed and adaptive 1K/2K and multiple references. Use an isolated workspace and fixed APP identity without asking the user for filesystem permissions. Inspect generated outputs and runtime logs.
6. Build and package, review the diff, commit and push main. Verify GitHub's build and the latest release asset match the final commit.

## Verification

Passed 12 Swift Core checks, 9 Setup checks, 36 Python tests and the complete native input, application state and inspector animation suites. First setup, Turbo path discovery, repeated references, clipboard imports, enhancement streaming and relaunch all passed. Release build, signature verification and ZIP restoration passed.

Real AppStore → ProcessRunner → LightX2V MPS tests used a new isolated workspace on an Apple M4 Pro, source commit `370878c09dec0227f1a52fdfbfab73bd0bf7ba1a` and the Turbo checkpoint. Each completed run reported all eight steps:

| Case | Output | References | Enhancement |
| --- | --- | ---: | --- |
| t2i, adaptive 1K | 1024 × 1024 | 0 | Off |
| i2i, square 1K | 1024 × 1024 | 1 | Off |
| i2i, landscape 1K | 1376 × 768 | 2 | Off |
| t2i, portrait 2K | 1792 × 2400 | 0 | Off |
| t2i, adaptive 1K | 1376 × 768 | 0 | On |
| i2i, adaptive 1K | 1024 × 1024 | 2 identical | On |
| i2i, adaptive 2K | 1792 × 2368 | 1 | Off |

Actual denoising cancellation and relaunch passed. Seven completed turns and one cancelled turn remained in one creation with different seeds; duplicate reference snapshots survived relaunch. The original workspace and locator checksums stayed unchanged. Native UI checks used isolated cache fixtures and required no user permission intervention. This matrix checks inference and interaction behavior; image content remains model-generated.
