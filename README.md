# LightX2V APP

适用于 Apple Silicon Mac 的本地图像生成应用，基于 [LightX2V](https://github.com/ModelTC/LightX2V)，目前支持 **Qwen-Image-2.1 文生图与多图编辑**。

**[下载最新 APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip)** · [查看构建](https://github.com/ModelTC/LightX2V-Mac-App/actions)

每次提交自动构建，下载页只保留最新安装包，无自动过期时间。

## 开始使用

需要 **M 系列芯片的 Mac、macOS 14+**，以及模型权重和支持 PyTorch MPS 的 Python 环境。安装包不包含模型和推理环境。

1. 下载并解压，将 `LightX2V APP.app` 放入「应用程序」。
2. 首次打开，先选 **LightX2V 工作目录**；源码可自动下载或手动选择，再搜索并选择 **PyTorch 环境**。保存后会自动记住，之后可通过左下角齿轮修改。
3. 选择 **Qwen-Image-2.1**，在右侧「模型准备」选择模型目录和 Config，点击「保存并检查」。配置使用 LightX2V 中的 `configs/platforms/mps/qwen_image_21_viggle_v03.json`，模型使用对应的 merged 权重。
4. 输入提示词，选择尺寸，按 **Return** 生成（Shift + Return 换行）。如需编辑图片，点击输入框的 **＋** 或将图片拖入，建议 1–3 张、最多 8 张；可按缩略图编号描述各图。

macOS 如询问工作目录或模型的文件访问权限，请允许，否则环境检查和推理可能无法继续。

通过 **1K / 2K 和七种固定比例或「自适应」**选择分辨率，默认 **1K、1:1（1024 × 1024）**。自适应跟随参考图比例（多图时取最后一张，无图时为 1:1），由 LightX2V 确定实际宽高，需要源码支持 `--resolution` 参数。每次生成自动使用随机种子。生成结果可预览、导出，并从历史记录复用提示词、输入图片与尺寸选择。

当前 6 步配置建议优先使用 **1K、1–3 张参考图**。本机实测中，2K 有明显噪点，8 张参考图出现失真；这些情况也在[模型效果验证较有限的范围](https://huggingface.co/Viggle/Qwen-Image-2.1-viggle-turbo#known-limitations)内。

输入图片会保存独立副本，原文件移动或删除不影响历史复用。支持系统可读取的静态图片格式，每张不超过 100 MB、4000 万像素；动图仅使用首帧。

工作目录统一保存配置与历史、`outputs` 图片与日志、`cache` 缓存，以及 `code/LightX2V-[commit]` 源码（不含 Git 历史）。更换目录时不迁移旧历史或作品，新目录从空历史开始。工作目录路径记录在 `~/Library/Application Support/LightX2V APP/workspace_location.json`，下次启动自动读取。

首次打开若提示无法验证开发者，可在「系统设置 → 隐私与安全性」中选择「仍要打开」。当前安装包尚未进行 Apple 公证。

## 源码构建

安装 Apple Command Line Tools 后运行：

```bash
git clone https://github.com/ModelTC/LightX2V-Mac-App.git
cd LightX2V-Mac-App
bash scripts/build.sh
open "dist/LightX2V APP.app"
```
