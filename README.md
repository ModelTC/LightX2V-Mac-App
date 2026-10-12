# LightX2V APP

A native macOS app for local image generation with [Qwen-Image-2.1-Turbo](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo) on Apple Silicon. It uses [LightX2V](https://github.com/ModelTC/LightX2V) for image inference and [llama.cpp](https://github.com/ggml-org/llama.cpp) for optional prompt enhancement, with a simple interface for text-to-image and image-to-image creation.

## Download

| Channel | Apple Silicon · macOS 14+ | Commit | Updates |
| --- | --- | --- | --- |
| Latest | [Download Latest APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip) | [`074cfc1`](https://github.com/ModelTC/LightX2V-Mac-App/commit/074cfc17ad3dd916098a34399d77fe38d01929c4) | Every successful build |
| Stable | [Download Stable APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/stable/LightX2V-APP-macOS-arm64.zip) | [`90fac91`](https://github.com/ModelTC/LightX2V-Mac-App/commit/90fac918f500d722d0f082c617c76f6a2330241e) | Manually promoted releases |

Each channel keeps one APP package. Updating Stable replaces its previous package; ordinary builds only update Latest.

[Promote Latest to Stable](https://github.com/ModelTC/LightX2V-Mac-App/actions/workflows/promote-stable.yml)

**First launch on macOS:** macOS may block the APP because the developer cannot be verified. After attempting to open it, go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** for LightX2V APP. Authenticate if prompted, then confirm **Open**. Only do this for an APP downloaded from this repository's releases.

## Build from source

Install Apple's Command Line Tools, then run:

```bash
git clone https://github.com/ModelTC/LightX2V-Mac-App.git
cd LightX2V-Mac-App
bash scripts/build.sh
open "dist/LightX2V APP.app"
```
