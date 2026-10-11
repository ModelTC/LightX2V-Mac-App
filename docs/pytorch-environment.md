# 安装 PyTorch 环境

需要 Apple Silicon 的 Python 环境，MPS 可用，且满足：

- torch ≥ 2.14.1
- torchvision ≥ 0.29.1
- torchaudio ≥ 2.11.0
- transformers ≥ 5.19.0

在 APP 的「通用设置 → 搜索本机环境」中，选择「查看安装说明」。APP 会把完整依赖文件存入工作目录的 `environments/requirements.txt`，并提供可复制的终端命令，用 Python 3.11 创建环境、安装依赖及执行 `pip check`。

也可以选择「安装 TorchLightX2V」。APP 会从 [Miniconda 官方源](https://repo.anaconda.com/miniconda/) 下载并校验 Apple Silicon 安装器，在工作目录的 `environments/miniconda3` 中安装 Miniconda，再创建 Python 3.11 环境 `TorchLightX2V`，并安装同一份依赖。安装过程支持取消、查看日志及继续安装。

两种方式安装完成后，都请重新点击「搜索本机环境」，选择检测通过的环境。

Miniconda 官方安装器要求安装路径不含空格。工作目录路径包含空格时，请使用「自行安装」，或更换无空格的工作目录。
