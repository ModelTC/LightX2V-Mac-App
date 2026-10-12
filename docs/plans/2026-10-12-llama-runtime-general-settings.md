# llama.cpp General Settings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move the shared llama.cpp bin path to the fourth general setting and download the specified b11564 Apple Silicon release into the workspace.

**Architecture:** Keep the existing serialized Prompt enhancement runtime path so configured installations retain their selection; general settings owns editing and saving this path. Download the pinned archive to an isolated workspace staging directory, validate its SHA-256 and tar entries, preserve its executables and dynamic libraries in a versioned runtime folder, then fill the bin path. General setup validates all four paths.

**Tech Stack:** SwiftUI, AppKit, Foundation URLSession, CryptoKit, macOS tar, existing cancellable SetupCommand.

---

### Task 1: Shared configuration

**Files:** Sources/LightX2VCore/GeneralSetupProgress.swift, Models.swift, PromptEnhancement.swift, Sources/LightX2VApp/AppStore.swift.

1. Add the fourth setup step and normalize its bin path in the setup guide.
2. Require the bin path in general settings and validate executable llama-completion and llama-mtmd-cli files.
3. Save only the runtime path from the general draft, preserving independently saved enhancement model settings.
4. Ensure enhancement model edits and model discovery retain the shared runtime selected in general settings.
5. Update path-validation and startup fixtures and verify incomplete fourth-step startup routing and persisted existing runtime paths.

### Task 2: Workspace download

**Files:** Create Sources/LightX2VCore/LlamaRuntimeDownloader.swift; modify WorkspaceStorage.swift; create Tests/SetupChecks/LlamaRuntimeDownloadChecks.swift.

1. Pin b11564 to the requested URL and official SHA-256 fa7897448562888373f1c4d393dc860da78873e0fbc230fd17312e0e972af844.
2. Stream progress and support cancellation, HTTP failures, malformed archives, checksum mismatch, and reuse of a complete installation.
3. Validate tar paths and symlink targets before extraction; install the complete archive root as runtimes/llama.cpp-b11564/bin without overwriting existing directories.
4. Copy a managed runtime when switching workspaces, retaining the original workspace and rebasing the shared bin path.
5. Verify fixtures for download, failure, cancellation, and reuse; verify the real official package in a fresh workspace.

### Task 3: Settings interfaces

**Files:** Sources/LightX2VApp/GeneralSettingsView.swift, PromptEnhancementView.swift, Tests/AppStateChecks/SettingsFocusChecks.swift, StartupEnvironmentChecks.swift.

1. Add the fourth section with manual directory selection, automatic download, progress, cancellation, and error display; update the four-step count.
2. Remove the editable runtime path from Prompt enhancement and direct missing-runtime messages to general settings.
3. Retain explicit Save and Close behavior for manual settings operations.
4. Inspect first-launch/general-settings and enhancement-setting snapshots; verify focus, startup, configuration saving, and enhancement app-state checks.

### Task 4: Verification and release

1. Build and run core, setup, and app-state checks with isolated build, temporary, and app-support directories.
2. Compare original workspace hashes, run git diff --check, commit and push main.
3. Wait for the matching GitHub Actions run and verify the release tag, asset label, SHA-256, and download URL against this commit.
