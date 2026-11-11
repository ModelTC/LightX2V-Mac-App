# LightX2V

A native macOS app for local image generation with [Qwen-Image-2.1-Turbo](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo) on Apple Silicon. It uses [LightX2V](https://github.com/ModelTC/LightX2V) for image inference and [llama.cpp](https://github.com/ggml-org/llama.cpp) for optional prompt enhancement, with a simple interface for text-to-image and image-to-image creation. Verified on an Apple M4 Pro with 24GB of unified memory.

## Download

| Channel | Apple Silicon · macOS 14+ | Commit | Date (UTC+8) |
| --- | --- | --- | --- |
| Latest | [Download Latest APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip) | [`65acaee`](https://github.com/ModelTC/LightX2V-Mac-App/commit/65acaee0c063200651629cb21df7c46711687e65) | 2026-11-11 20:59 |
| Stable | [⬇️ Download Stable APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/stable/LightX2V-APP-macOS-arm64.zip) · **⭐ Recommended** | [`6c82470`](https://github.com/ModelTC/LightX2V-Mac-App/commit/6c82470697bf1dc1b4df54bb7a5187983574c76a) | 2026-10-14 15:51 |

Each channel keeps one app package. Updating Stable replaces its previous package; ordinary builds only update Latest.

[Promote Latest to Stable](https://github.com/ModelTC/LightX2V-Mac-App/actions/workflows/promote-stable.yml)

**First launch on macOS:** macOS may block the app because the developer cannot be verified. After attempting to open it, go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** for LightX2V. Authenticate if prompted, then confirm **Open**. Only do this for an app downloaded from this repository's releases.

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
open "dist/LightX2V.app"
```
