# LightX2V APP

A native macOS app for local image generation with [Qwen-Image-2.1-Turbo](https://huggingface.co/Qwen/Qwen-Image-2.1-Turbo) on Apple Silicon. It uses [LightX2V](https://github.com/ModelTC/LightX2V) for image inference and [llama.cpp](https://github.com/ggml-org/llama.cpp) for optional prompt enhancement, with a simple interface for text-to-image and image-to-image creation.

## Download

| Channel | Apple Silicon · macOS 14+ | Commit | Updates |
| --- | --- | --- | --- |
| Latest | [Download Latest APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip) | [`947ef23`](https://github.com/ModelTC/LightX2V-Mac-App/commit/947ef238b9ca6a9bf07f5744e59e630815907563) | Every successful build |
| Stable | [Download Stable APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/stable/LightX2V-APP-macOS-arm64.zip) | [`947ef23`](https://github.com/ModelTC/LightX2V-Mac-App/commit/947ef238b9ca6a9bf07f5744e59e630815907563) | Manually promoted releases |

Each channel keeps one APP package. Updating Stable replaces its previous package; ordinary builds only update Latest.

[Promote Latest to Stable](https://github.com/ModelTC/LightX2V-Mac-App/actions/workflows/promote-stable.yml)

## Build from source

Install Apple's Command Line Tools, then run:

```bash
git clone https://github.com/ModelTC/LightX2V-Mac-App.git
cd LightX2V-Mac-App
bash scripts/build.sh
open "dist/LightX2V APP.app"
```
