# Qwen Image 2.1 Turbo INT8 Metal

The App bundles upstream LightX2V release `0.6.1`, resolving to commit
`43c6a11bb65b7357f06e9603fa92249bc16b484e`. Its pruned source archive includes
the Apple INT8 kernel Python package. The bridge adds it to `PYTHONPATH`
for INT8 inference. The source package excludes `lightx2v_rl`. Setup extracts
the bundled source into the workspace. If the source archive is absent, the app
downloads the official `0.6.1` archive. Startup also repairs missing source files
in managed installations.

Download the complete `lightx2v/Qwen-Image-2.1-Turbo-INT8` model. No
`apple_silicon_metal/manifest.json` is required. The App ships its own integrity
metadata in `Sources/LightX2VCore/Resources/qwen_image_21_turbo_int8_metal.json`,
recording the sizes and SHA-256 values of the three official libraries from
model revision `b572c2d129f1f440c1643e1be730ac1336f2d5d5`. Both Swift model
preparation and the Python bridge verify these libraries. This checks library
integrity, not the contents of all model weights.

The bridge exports `LIGHTX2V_METALLIB_DIR=<model>/apple_silicon_metal` and uses
the upstream `dit_quantized=true`, `dit_quant_scheme=int8-metal` configuration.
The selected Python environment needs PyTorch 2.14.1 or later with
`torch.mps.load_metallib`; the official libraries require macOS 26.4+ and were
validated on Apple M5. A missing or corrupted library fails before inference.

When downloading the standard or INT8 model in the app, the downloader can
reuse the text encoder and VAE from the other variant in the same workspace.
It resolves the chosen Hugging Face or ModelScope revision and checks the
shared files against that revision before using filesystem cloning. After a
successful reuse, the remaining download stays pinned to that revision. If
metadata or cloning is unavailable, the normal download handles those files.

To update the supported libraries, verify the official model snapshot, update
the bundled metadata and test fixtures together, and run the local Core,
setup, bridge, and package checks. To update the engine, update the release
archive URL, source root, source/bundle hashes, and versioned installation path
together. Existing runtime directories are preserved.
