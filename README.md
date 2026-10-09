# LightX2V APP

[![Build macOS App](https://github.com/ModelTC/LightX2V-Mac-App/actions/workflows/build-macos.yml/badge.svg?branch=main)](https://github.com/ModelTC/LightX2V-Mac-App/actions/workflows/build-macos.yml)

适用于 Apple Silicon Mac 的原生图像生成应用。采用 SwiftUI / AppKit，界面参考 Codex 的侧边栏、创作区和底部输入框，首版支持 **Qwen-Image-2.1 / Viggle v0.3 文生图**。

## 自动构建与下载

**[下载最新 APP](https://github.com/ModelTC/LightX2V-Mac-App/releases/download/latest/LightX2V-APP-macOS-arm64.zip)** · [查看版本信息与校验值](https://github.com/ModelTC/LightX2V-Mac-App/releases/tag/latest)

构建包通过固定的 `latest` GitHub Release 发布，**没有自动过期时间，只保留最新成功构建的 APP**。公开仓库的 Release 下载无需登录 GitHub，下载链接保持不变。

每次向本仓库 push（任意分支或标签，自动维护的 `latest` 标签除外），[Build macOS App](https://github.com/ModelTC/LightX2V-Mac-App/actions/workflows/build-macos.yml) 都会自动执行：

1. 在 GitHub 的 macOS 15 / Apple Silicon runner 上运行 Swift 核心检查和 Python 桥接集成测试。
2. 编译 arm64 Release 应用并完成 ad-hoc 签名。
3. 生成 ZIP，重新解压检查签名、可执行权限和内容一致性。
4. 上传并验证新包后，将 `latest` Release 中的 `LightX2V-APP-macOS-arm64.zip` 替换为新版，清理旧 APP 包；`macos-arm64` Deployment 始终指向这个 Release。

可以从上方固定链接、仓库 **Releases**、[Deployments](https://github.com/ModelTC/LightX2V-Mac-App/deployments) 或 Actions 运行摘要下载。Release 说明记录最新包的提交 SHA、构建记录和 SHA-256 校验值。旧的 Actions APP 附件会在新版成功发布后清理，不再另存有期限的构建副本；Actions 日志和构建历史继续保留。旧运行摘要中的固定链接也会指向当前最新版。

解压后将 `LightX2V APP.app` 放入「应用程序」目录即可。当前为 ad-hoc 签名，尚未进行 Apple Developer ID 签名和公证；从网络下载后，macOS 可能需要在「系统设置 → 隐私与安全性」中确认打开。模型、LightX2V 源码和 Python 推理环境仍需在本机配置。

可以通过该工作流页面的 **Run workflow** 手动构建指定分支。每次 push 按该次推送的 HEAD 构建；检查或编译失败时，保留上一版下载。发布流程串行执行，连续快速 push 时保留正在执行的构建和等待队列中的最新一次，避免多个流程同时覆盖下载包。重跑旧工作流不会覆盖更新的成功版本。此处「最新」按本工作流的运行编号判断，适用于所有触发分支。

CI 只安装轻量测试依赖，不下载模型、不执行真实模型推理，也不需要配置额外的 GitHub PAT 或 Apple 证书。`latest` 为持续更新的标签，请勿将该 Release 设为 immutable；滚动发布需要更新它的标签与附件。Release 不受 Actions 附件保留天数限制，但手动删除 Release 或仓库仍会使链接失效。

## 开始使用

克隆仓库并构建应用：

```bash
git clone https://github.com/ModelTC/LightX2V-Mac-App.git
cd LightX2V-Mac-App
bash scripts/build.sh
open "dist/LightX2V APP.app"
```

需要 Apple Silicon Mac、macOS 14+ 和 Apple Command Line Tools。运行推理还需要本地 LightX2V 源码、Qwen-Image-2.1 merged 模型和已安装依赖的 Python 环境。

构建完成后，双击 **dist/LightX2V APP.app**，也可以将它拖到「应用程序」目录。应用无需安装 Node.js、Electron 或启动网页服务。

1. 等待左下角显示 **Apple Silicon · MPS**。
2. 输入提示词，或点击首页的示例灵感。输入框底部的模型下拉菜单可选择模型；目前支持 Qwen-Image-2.1，也可从菜单中的「模型准备」跳转到右侧的模型路径设置。
3. 右侧「生成参数」只保留画面尺寸预设、宽高和随机种子；默认 1024×1024、种子 42。
4. 点击「生成」或按 **⌘ Return**。
5. 完成后可预览、复制、拖出图片、另存为或在 Finder 中查看。

默认使用当前用户主目录下的以下路径，可在设置中修改：

| 项目 | 路径 |
| --- | --- |
| LightX2V | `~/Documents/x2v/LightX2V` |
| 模型 | `~/Documents/x2v/models/Qwen/Qwen-Image-2.1-merged` |
| 配置 | `~/Documents/x2v/LightX2V/configs/platforms/mps/qwen_image_21_viggle_v03.json` |
| Python | `/opt/miniconda3/envs/torch/bin/python` |
| 生成结果 | `~/Pictures/LightX2V/` |

`~` 表示当前用户主目录，应用会自动展开为绝对路径；手动编辑设置时请填写绝对路径。Python 优先检测 `/opt/miniconda3/envs/torch/bin/python`，也支持选择其他已配置的环境。

左下角齿轮或 **⌘ ,** 打开「通用设置」，只设置 **LightX2V 源码目录、Python 可执行文件、生成结果目录**。右侧「生成参数」上方的「模型准备」设置 **模型目录、Config 配置**，支持手动输入和文件选择。两处独立保存，通用设置中的「恢复默认路径」不会重置模型路径。

修改模型路径后点击「保存并检查」，也可「撤销修改」。未保存时暂不能生成，以免继续使用旧路径；收起右侧栏会保留未保存的输入。「保存并检查」会检查路径、6 步 MPS 配置、PyTorch MPS 实际运算和 LightX2V CLI 导入，不会加载完整模型。

## 已实现

- 原生 macOS 桌面窗口，中文界面，历史搜索、创建新任务、参数侧栏。
- 本地 Qwen-Image-2.1 文生图：固定 Viggle v0.3 的 6 步与 sigma 调度。
- 自定义宽高、比例预设、固定种子、随机种子；记录实际使用的 seed。
- 按真实日志更新生成阶段和当前步数，不模拟百分比。
- 随时停止生成；子进程不响应时在 3 秒后强制停止。
- 单任务运行，生成结束后退出 Python 推理进程并释放模型资源。
- 每次生成独立保存 PNG、完整日志、请求、实际命令、配置快照和任务状态。
- 历史持久化、失败详情、参数复用、图片复制与导出；移除历史仅移除索引，保留输出文件。
- 退出应用时处理正在运行的任务；异常退出后将未完成任务标记为中断。

首版限定文生图；尚未提供图像编辑、视频生成、任务队列、模型下载或常驻模型服务。每张图片都会重新载入模型。

## 与参考脚本的关系

沿用 `scripts/platforms/mps/qwen_image_21_viggle_v03.sh` 的关键参数：

```text
PLATFORM=mps
DTYPE=BF16
SENSITIVE_LAYER_DTYPE=None
PROFILING_DEBUG_LEVEL=2
python -u -m lightx2v.infer
  --model_cls qwen_image_21 --task t2i
  --model_path <模型目录>
  --config_json <本次任务的配置快照>
  --prompt <原样传递的提示词>
  --size <高> <宽>
  --seed <实际种子>
  --save_result_path <本次任务目录>/image.png
```

同时设置 `PYTHONPATH`、`TOKENIZERS_PARALLELISM=false` 和脚本中的 allocator 变量；保留磁盘流式加载和 CPU offload。Hugging Face 以离线模式运行。通过参数数组启动进程，提示词中的引号、换行和 shell 字符不会被当作命令执行。

没有修改现有 LightX2V 源码、参考脚本、模型权重或 Python 依赖。

## 文件与快捷键

每次生成的结果保存在 `~/Pictures/LightX2V/时间-任务ID/`：

```text
image.png         生成图片（成功后）
request.json      提示词、尺寸、种子、源路径
config.json       推理配置快照
invocation.json   Python argv 与工作目录
inference.log     完整推理日志
generation.json   状态、时间与错误详情
```

应用配置与历史索引保存在 `~/Library/Application Support/LightX2V APP/workspace.json`。更改输出目录不会移动已有作品。

| 快捷键 | 操作 |
| --- | --- |
| ⌘ N | 新建创作 |
| ⌘ Return | 生成图片 |
| ⌘ . | 停止生成 |
| ⌘ , | 设置 |
| ⌘ ⇧ L | 切换日志 |
| ⌘ ⌥ I | 切换参数侧栏 |

## 本机验证

2026-10-09，在 macOS 15.6.1、Apple Silicon / 24 GiB、Python 3.11.14、PyTorch 2.14.0 上完成：

| 验证项目 | 结果 |
| --- | --- |
| Swift 参数校验、Unicode / 大种子序列化、异常恢复、原子历史存储 | 4 项通过 |
| Python 命令参数、非方形尺寸顺序、Unicode 日志、失败回报、取消与强制结束、覆盖保护、配置校验 | 5 项集成测试通过 |
| 512×512 / 6 步 / seed 42，真实 MPS | 成功，33.24 秒 |
| 1024×1024 / 6 步 / seed 42，真实 MPS | 成功，96.92 秒 |
| 从原生界面生成 512×768 / 6 步 / seed 42 | 成功，43.31 秒 |
| 原生界面实时日志、阶段与步数 | 通过 |
| 从原生保存面板导出 PNG | 通过，与原文件逐字节一致 |
| 从原生界面停止正在运行的推理 | 通过，无残留推理进程 |
| 重启后历史与图片预览恢复 | 通过 |
| arm64 release 构建、应用签名校验 | 通过 |

时间为开发机单次实测，含 Python 启动和模型加载，会随尺寸、缓存和系统负载变化。生成图片、模型权重、运行日志和构建产物不纳入源码仓库。

## 构建与开发

需要 macOS 14+、Apple Silicon 与 Apple Command Line Tools。本机无需完整 Xcode；核心测试使用独立 Swift 检查程序，以避免依赖 XCTest。

在本源码目录运行：

```bash
bash scripts/build.sh
```

默认输出到仓库中的 `dist/LightX2V APP.app`，构建缓存写入 `.build/`；两者均已加入 `.gitignore`。也可明确指定输出与缓存：

```bash
LIGHTX2V_BUILD_DIR=/path/to/build-cache bash scripts/build.sh "/path/to/LightX2V APP.app"
```

开发运行与测试：

```bash
swift run LightX2VApp
swift run LightX2VCoreChecks
python3 -m pip install -r Tests/requirements.txt
python3 -m unittest discover -s Tests -v
```

Python 测试使用隔离的临时 CLI 和 Pillow，不加载模型权重；请使用已安装 Pillow 的 Python 环境（可直接使用推理环境）。SwiftUI 中的应用状态通过 `AppStore` 管理，Python 桥接程序通过 NDJSON 发送事件。

生成与 CI 相同格式的可下载 ZIP（需先完成构建）：

```bash
bash scripts/package.sh
```

输出为 `dist/LightX2V-APP-macOS-arm64.zip` 和对应的 `.sha256` 文件。

```text
SwiftUI 界面 → AppStore → Foundation Process → bridge.py
                                              ↓
                                    python -m lightx2v.infer
                                              ↓
                                 日志 / 阶段 / PNG / 持久化记录
```

`LIGHTX2V_APP_STATE_DIR` 环境变量可将开发实例的状态存储隔离到测试目录。

此版本是适用于本机的 ad-hoc 签名构建，应用约 2.3 MB，模型和 Python 环境不包含在安装包中。向其他 Mac 正式分发时，需要独立配置推理环境，并使用开发者签名和公证流程。

## 常见问题

- **环境检查失败：** 在设置中选择安装了 LightX2V 依赖且支持 MPS 的 Python。不要直接选择缺少依赖的系统 Python。
- **找不到模型：** 选择完整的 merged 模型目录，确保其中 `text_encoder`、`processor`、`vae` 的符号链接仍有效。
- **配置被拒绝：** 选择参考脚本对应的 MPS / Viggle v0.3 JSON。首版不接受不同步数或普通 Qwen 配置。
- **出现 flash-attn / sageattention 缺失提示：** 本配置使用 `torch_sdpa_mps`；这些可选 CUDA 模块的启动提示不等同于 MPS 推理失败。以最终状态和完整异常为准。
- **生成失败或内存不足：** 查看任务的 `inference.log`，可先将右侧宽和高都设为 512。应用不会自动降低精度或修改系统内存限制。
- **重现某次任务：** 查看对应任务的 `invocation.json` 和 `config.json`；「复用参数」会带入提示词、宽高与实际 seed，后续运行使用当前应用设置。
