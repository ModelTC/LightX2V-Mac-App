# LightX2V APP

A native macOS app for local image generation with [Qwen-Image-2.1-Turbo](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo) on Apple Silicon. It uses [LightX2V](https://github.com/ModelTC/LightX2V) for image inference and [llama.cpp](https://github.com/ggml-org/llama.cpp) for optional prompt enhancement, with a simple interface for text-to-image and image-to-image creation. Verified on an Apple M4 Pro with 24GB of unified memory.

## Download

| Channel | Apple Silicon · macOS 14+ | Commit | Date (UTC+8) |
| --- | --- | --- | --- |
| Latest | [Download Latest APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip) | [`dad560b`](https://github.com/ModelTC/LightX2V-Mac-App/commit/dad560bd2b90eb9d4228f913531762776cedd56d) | 2026-10-14 15:11 |
| Stable | [⬇️ Download Stable APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/stable/LightX2V-APP-macOS-arm64.zip) · **⭐ Recommended** | [`daf5fe0`](https://github.com/ModelTC/LightX2V-Mac-App/commit/daf5fe00df9048943a78e194e43ddac6053f7f06) | 2026-10-14 02:13 |

Each channel keeps one APP package. Updating Stable replaces its previous package; ordinary builds only update Latest.

[Promote Latest to Stable](https://github.com/ModelTC/LightX2V-Mac-App/actions/workflows/promote-stable.yml)

**First launch on macOS:** macOS may block the APP because the developer cannot be verified. After attempting to open it, go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** for LightX2V APP. Authenticate if prompted, then confirm **Open**. Only do this for an APP downloaded from this repository's releases.

## Supported models

- [Qwen-Image-2.1-Turbo](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo)
- [Qwen-Image-2.1-PE-T2I-GGUF-Q8_0](https://huggingface.co/lightx2v/Qwen-Image-2.1-PE-T2I-GGUF-Q8_0)
- [Qwen-Image-2.1-PE-I2I-GGUF-Q8_0](https://huggingface.co/lightx2v/Qwen-Image-2.1-PE-I2I-GGUF-Q8_0)

## Build from source

Install Apple's Command Line Tools, then run:

```bash
git clone https://github.com/ModelTC/LightX2V-Mac-App.git
cd LightX2V-Mac-App
bash scripts/build.sh
open "dist/LightX2V APP.app"
```
