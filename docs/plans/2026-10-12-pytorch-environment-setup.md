# PyTorch Environment Setup Implementation Plan

> **For Claude:** Follow the steps below in order; verify each behavior before delivery.

**Goal:** Discover environments meeting all four requested minimum versions and provide manual instructions or a workspace-local Miniconda installation when none qualify.

**Architecture:** Keep discovery and installation in LightX2VCore. Bundle the user's requirements file with the app. A settings sheet presents search results, two installation choices, cancellable installation progress, and an explicit search-again action. Installation creates a Python 3.11 environment named TorchLightX2V inside the selected workspace and never selects an unverified environment.

**Tech Stack:** Swift, SwiftUI, Foundation, CryptoKit, POSIX process groups, official Miniconda arm64 installer, Conda, pip.

---

### Task 1: Version requirements and discovery

- Modify `Sources/LightX2VCore/PythonEnvironmentSearch.swift`.
- Add minimum-version comparison and collect torch, torchvision, torchaudio and transformers versions.
- Require all four versions and an available MPS backend for selection; explain each rejection.
- Search the workspace's managed Miniconda environments and manual venv location.
- Extend `Tests/SetupChecks/SetupChecks.swift` for exact versions, newer versions, missing packages, prereleases, invalid versions and duplicate executable aliases.

### Task 2: Installation services

- Extend `Sources/LightX2VCore/SetupCommand.swift` with streamed log lines, persistent installation logs, environment overrides and process-group cancellation.
- Add `Sources/LightX2VCore/PyTorchEnvironmentInstaller.swift`.
- Use a versioned official arm64 Miniconda installer and its published SHA-256. Download/cache under the workspace and verify before executing.
- Install Miniconda under `environments/miniconda3`; create `envs/TorchLightX2V` there with Python 3.11 and pip, using conda-forge.
- Install the exact bundled requirements, run pip check and probe the resulting environment. Retain failed environments for retry; never overwrite an unrelated existing directory.
- Stream stages and log lines. Cancel child processes on cancellation or app exit. Allow retry of managed partial installations.
- Surface the official Miniconda constructor's space-free-prefix requirement before downloading; keep the manual venv route available for paths containing spaces.
- Bundle `/Users/yongyang/Documents/x2v/requirements.txt` as `Sources/LightX2VApp/Resources/requirements.txt` and add it to `Package.swift` resources.
- Add fixture-based installer tests for success, reuse, failure, cancellation, unrelated-folder protection and paths containing spaces.
- Verify byte progress, cache reuse, SHA-256 rejection, HTTP errors and download cancellation with a local HTTP fixture.

### Task 3: Settings UI and help

- Modify `Sources/LightX2VApp/GeneralSettingsView.swift`; add a focused environment setup sheet if needed.
- Rename the action to “搜索本机环境”. Show minimum versions and compatible/rejected results.
- After an unsuccessful complete search, display two equally clear choices: manual installation instructions and installation in the workspace.
- Keep the installation UI compact, with steps, bounded logs, cancellation, retry and “搜索本机环境” after success. Do not auto-select after installation.
- Add `docs/pytorch-environment.md` with concise manual installation instructions; keep README unchanged.
- Verify native focus, initial state, search completion, both choices, installation progress/error/success and keyboard interaction using the persistent cache-based UI fixture.

### Task 4: Verification and publication

- Run `swift run LightX2VSetupChecks` and `swift run LightX2VCoreChecks`.
- Run the native app-state/input checks impacted by the settings sheet and the Python integration checks.
- Build and inspect the app's bundled requirements.
- Commit and push to the authorized main branch; verify CI and the latest release package match the commit.

## Validation performed

- 9 setup checks passed, including dependency comparison, installer download progress and cancellation, new environment discovery, installation failure/retry, unrelated-folder protection and descendant process cancellation.
- 11 core checks and 36 Python bridge integration tests passed.
- Native settings checks preserve neutral initial focus and keyboard navigation. All search, help, progress, cancellation, failure and completion layouts fit the settings sheet.
- Native input/cursor/scrollbar and inspector clipping checks passed.
- A real installation in an isolated cache workspace completed with Python 3.11.17, torch 2.14.1, torchvision 0.29.1, torchaudio 2.11.0 and transformers 5.19.0. `pip check`, all four imports, OpenCV, LightX2V import and a real MPS tensor operation passed.
- The user's requirements file is bundled byte-for-byte; signed app/archive resource checks passed.
