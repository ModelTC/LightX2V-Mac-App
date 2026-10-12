# Multilingual Interface Implementation Plan

**Goal:** Add ten interface languages and a first-position language picker, while keeping all APP-authored diagnostic logs in English.

**Architecture:** Use standard localized Swift Package resources and a shared observable application preference independent of workspace storage. Store operational messages in English and translate them at display time so switching languages updates existing status without restarting tasks. Keep prompts, generated text, commands, paths and third-party logs untouched.

**Tech Stack:** SwiftUI, Foundation localization resources, UserDefaults, existing SwiftPM/macOS packaging.

1. Add localized resources and language preference management with system matching, English fallback and an isolated preference suite for checks.
2. Localize UI labels, menus, accessibility, dialogs and dynamic status rendering; add compact language row as item 1 and renumber path cards 2–5.
3. Normalize core, Swift and Python APP-authored log messages to English. Preserve model output and subprocess output.
4. Include all translation resources in native APP packaging without adding GitHub test jobs.
5. Validate locale completeness, formatting, fallback, persistence, English log output, macOS compilation and native UI in isolated directories. Verify long-language and Arabic layouts, preserve originals, clean generated artifacts.
6. Commit and push; verify matching GitHub build, release SHA and downloaded package digest, then provide the APP link.
