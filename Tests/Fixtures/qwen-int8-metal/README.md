# Official INT8 Metal Library Fixtures

The three small GPU libraries come from `apple_silicon_metal/` in
`lightx2v/Qwen-Image-2.1-Turbo-INT8` at revision
`b572c2d129f1f440c1643e1be730ac1336f2d5d5`:
https://huggingface.co/lightx2v/Qwen-Image-2.1-Turbo-INT8/tree/b572c2d129f1f440c1643e1be730ac1336f2d5d5/apple_silicon_metal

They contain compiled kernel code, not model weights. Source and license:
https://github.com/ModelTC/LightX2V/tree/19c19614b067f1746ac24350dfd097e1c0b48591/lightx2v_kernel/apple

Fixtures intentionally contain no model manifest. Their sizes and SHA-256 values
are recorded in the App's `qwen_image_21_turbo_int8_metal.json` resource.
