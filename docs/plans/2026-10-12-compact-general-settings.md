# Compact General Settings Implementation Plan

**Goal:** Show all four required settings in the default window and keep their fields and controls stationary during downloads, checks, errors and completion.

**Architecture:** Replace the scrolling expanded cards with four compact cards. Put each uniformly named “选择” button immediately to the right of its path. Keep download, search and check buttons below, alongside fixed progress slots. Remove inline purpose text; retain explanations and full results in detail popovers. Preserve existing download, save, close and startup behavior; a fixed footer names incomplete configuration and focuses its input on request.

**Tech Stack:** SwiftUI, AppKit, native input focus, existing cancellable resource tasks and app-state checks.

---

### Task 1: Compact fixed layout

Files: Sources/LightX2VApp/GeneralSettingsView.swift, PathInputField.swift, SettingsView.swift.

1. Render four compact cards without a scroll view; retain readable text and all path and primary action controls.
2. Reserve each card's status line, spinner slot and cancellation space. Use single-line truncation with full detail popovers, including errors.
3. Display configured/unconfigured/invalid path states independently from Python dependency checking.
4. Keep header and footer heights fixed. Name remaining configuration and focus its path only when the user clicks the prompt.
5. Remove automatic scrolling and animated step relocation; preserve neutral initial focus, Tab navigation, explicit Save and Close.

### Task 2: Geometry and interaction verification

Files: Tests/AppStateChecks/GeneralSettingsLayoutChecks.swift, SettingsFocusChecks.swift, main.swift.

1. Measure all four native fields in the default settings sheet and first-launch card, without scrolling; inspect primary controls in production snapshots.
2. Sample field positions and fitting height across real view updates for source/runtime progress, cancellation, completion, long errors, environment checking, rejection, success and saving.
3. Capture production snapshots for empty configuration, missing fourth setting, busy downloads, environment failure and ready settings; inspect them visually.
4. Verify missing-field focus, normal editing, keyboard access and existing startup/save/close behavior.

### Task 3: Verification and publication

1. Build in a fresh isolated scratch directory and run relevant core, setup and full app-state checks.
2. Compare original workspace and locator hashes, check whitespace, commit and push main.
3. Wait for the corresponding GitHub Actions release; verify commit/tag/asset metadata and the downloaded APP package digest before providing the download link.
