# LightX2V APP

适用于 Apple Silicon Mac 的本地图像生成应用，基于 [LightX2V](https://github.com/ModelTC/LightX2V)，目前支持 **Qwen-Image-2.1 / Viggle v0.3 文生图**。

**[下载最新 APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip)** · [查看构建](https://github.com/ModelTC/LightX2V-Mac-App/actions)

每次提交自动构建，下载页只保留最新安装包，无自动过期时间。

## 开始使用

需要 **M 系列芯片的 Mac、macOS 14+**，以及本地 LightX2V 源码、模型权重和支持 PyTorch MPS 的 Python 环境。安装包不包含模型和推理环境。

1. 下载并解压，将 `LightX2V APP.app` 放入「应用程序」。
2. 首次打开时，设置 **LightX2V 源码目录、Python 可执行文件、生成结果目录**。保存后会自动记住，之后可通过左下角齿轮修改。
3. 在右侧「模型准备」选择模型目录和 Config，点击「保存并检查」。配置使用 LightX2V 中的 `configs/platforms/mps/qwen_image_21_viggle_v03.json`，模型使用对应的 merged 权重。
4. 输入提示词，选择尺寸，点击「生成」或按 **⌘ Return**。

通过 **1K / 2K 和七种画面比例**选择分辨率，默认 **1K、1:1（1024 × 1024）**。每次生成自动使用随机种子。生成结果可预览、导出，并从历史记录复用提示词与尺寸。

首次打开若提示无法验证开发者，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。当前安装包尚未进行 Apple 公证。

## 源码构建

安装 Apple Command Line Tools 后运行：

```bash
git clone https://github.com/ModelTC/LightX2V-Mac-App.git
cd LightX2V-Mac-App
bash scripts/build.sh
open "dist/LightX2V APP.app"
```
