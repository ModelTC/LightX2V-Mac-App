# Prompt keyboard behavior

- Handle unmodified Return and keypad Enter inside the native prompt editor only. Submit through the same AppStore action and availability checks as the send button.
- Route Shift+Return (including keypad Enter) to AppKit's native newline command. Leave other text-editing shortcuts and any Return received while the input method has marked text to AppKit. Inspect composition before AppKit handles the event so candidate confirmation cannot become a send after unmarking.
- Ignore held-key repeats and blank prompts. Preserve drafts when generation cannot start; existing successful-launch clearing remains authoritative.
- Remove the old visible shortcut caption and shortcut tooltip text. Add no new keyboard instructions; retain the existing Command+Return shortcut.
- Verify native key events for sending, newlines, selection, empty/busy drafts, key repeat, keypad Enter, and IME composition; run input regressions and build before publishing.

## Verification

- 144 native component checks passed, including 16 new prompt keyboard checks using the actual SwiftUI/AppKit bridge.
- Isolated APP: Shift+Return created a two-line draft; Return entered the existing generation validation flow with no added newline. An unconfigured model produced the expected validation error and preserved the draft. No model inference was run.
- The old shortcut caption is absent, and the Apple Silicon release build and signature verification passed.
