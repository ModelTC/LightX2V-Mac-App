# Workspace Setup Implementation Plan

**Goal:** 用工作目录、源码下载和 PyTorch 环境发现简化新用户的首次配置。

**Architecture:** Core 提供工作区存储迁移、固定 commit 的源码下载、有限范围环境搜索与隔离探测。SwiftUI 设置页按工作目录 → 源码 → 环境排列；耗时操作异步执行，支持取消、进度、错误重试。所有应用管理的数据放进工作目录，系统 Application Support 仅保存定位信息。

**Tech Stack:** SwiftUI / AppKit、Foundation URLSession / Process、Python 只读环境探测、GitHub commit archive。

## 1. 工作目录和持久化
- 修改 Models.swift，增加 workingDirectory，输出目录由工作目录/outputs 自动派生，兼容旧字段读取。
- 新建 WorkspaceStorage.swift：原子写入定位记录，迁移历史及关联图片/日志/请求文件；旧目录保留，已有目标工作区不得被覆盖。
- AppStore 先成功提交工作区再切换内存状态，换目录操作异步，存储不可用时不覆盖原数据。
- 将推理的缓存、临时目录及当前目录约束到工作目录。

## 2. 源码下载
- 新建 SourceDownloader.swift 和可取消子进程工具。
- 解析 main 的完整 commit SHA，再下载该 SHA 的 archive，避免 main 在下载过程中变化。
- 在工作目录内临时下载和解压，检查文件路径、infer.py 和无 .git，成功后原子改名为 code/LightX2V-<完整 SHA>。
- 已有完整版本复用；同名异常目录拒绝覆盖；取消或失败清理本次临时文件。

## 3. 环境发现
- 新建 PythonEnvironmentSearch.swift：扫描 Conda 注册表、常见 Conda/Homebrew/pyenv/uv/venv 路径与有限深度项目目录。
- 异步最多两个解释器并行探测，设置超时、取消和输出上限；保留不同 venv 的身份。
- 列表显示 Python、PyTorch、MPS 和不可用原因，可选择推荐可用环境，也可手动选择 Python 文件。

## 4. 交互
- SettingsView 按编号组织三张简洁配置卡片，工作目录最先选择。
- 源码按钮下载后自动填路径，环境搜索显示候选列表，选择后回填。
- 取消设置不提交配置；下载完成的源码作为可复用资源保留。
- 更新简短 README。

## 5. 验证与发布
- Core 检查：工作目录派生路径、旧配置迁移、搬迁失败、目标冲突和历史文件完整性。
- 服务检查：archive 校验、取消/失败/复用、Python 解释器身份去重、探测超时与 MPS 状态。
- 实际下载官方 main、搜索本机环境；使用独立临时工作区做 GUI 首次配置、保存重开和更换目录检查。
- 运行 Swift、原生输入、Python bridge 检查和 release 构建，提交推送，确认 CI 与 latest release 的 commit 一致。

## Verification completed

- Core and setup checks cover legacy state decoding, output migration, image/log preservation, managed source rebasing, occupied destination rejection and locator failure rollback.
- GitHub main download was exercised against the live repository; full commit archive validation and repeated-download reuse passed. Native UI cancellation/retry also passed, with staging files removed.
- Local discovery found the MPS-capable Conda environment and explained Python environments without PyTorch. Probe timeout, cancellation and distinct venv symlink identities are covered by checks.
- Native UI verified first-launch setup, download autofill, environment selection, saving, restarting without onboarding, cancelling drafts and migrating a legacy history entry.
- Existing prompt/IME, scrollbar, resolution and bridge integration checks remain passing.

## Revised workspace switching behavior

- Switching to a new directory starts with empty history. Existing history, images and logs are not imported, copied or deleted.
- Saving settings for the current workspace preserves its own history and output paths.
- The active directory is remembered in the user's macOS app information directory: `~/Library/Application Support/LightX2V APP/location.json`.
- Checks now verify empty new history, untouched original files, same-workspace history preservation and restart lookup through the system locator.
