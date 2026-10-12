# LightX2V APP

## Download

| Channel | Apple Silicon · macOS 14+ | Updates |
| --- | --- | --- |
| Latest | [Download Latest APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip) | Every successful build |
| Stable | [Download Stable APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/stable/LightX2V-APP-macOS-arm64.zip) | Manually promoted releases |

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
