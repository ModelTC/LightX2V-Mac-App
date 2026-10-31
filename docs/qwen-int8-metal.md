# Qwen Image 2.1 Turbo INT8 Metal

The App uses upstream LightX2V commit
`19c19614b067f1746ac24350dfd097e1c0b48591`, which includes the INT8 Metal
implementation from upstream PR #1633. It does not depend on PR #1647 or a
fork release. The pinned, pruned source archive includes the Apple kernel
Python package; the bridge adds it to `PYTHONPATH` for INT8 inference.

Download the complete `lightx2v/Qwen-Image-2.1-Turbo-INT8` model. No
`apple_silicon_metal/manifest.json` is required. The App ships its own integrity
metadata in `Sources/LightX2VCore/Resources/qwen_image_21_turbo_int8_metal.json`,
recording the sizes and SHA-256 values of the three official libraries from
model revision `b572c2d129f1f440c1643e1be730ac1336f2d5d5`. Both Swift model
preparation and the Python bridge verify these libraries. This checks library
integrity, not the contents of all model weights.

The bridge exports `LIGHTX2V_METALLIB_DIR=<model>/apple_silicon_metal` and uses
the upstream `dit_quantized=true`, `dit_quant_scheme=int8-metal` configuration.
The selected Python environment needs PyTorch 2.14+ with
`torch.mps.load_metallib`; the official libraries require macOS 26.4+ and were
validated on Apple M5. A missing or corrupted library fails before inference.

To update the supported libraries, verify the official model snapshot, update
the bundled metadata and test fixtures together, and run the local Core,
setup, bridge, and package checks. To update the engine, update the immutable
archive URL, source root, source/bundle hashes, and versioned installation path
together. Existing runtime directories are preserved.
