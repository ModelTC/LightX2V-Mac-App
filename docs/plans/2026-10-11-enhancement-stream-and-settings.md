# Enhancement Reply and Settings Refinement

**Goal:** Make prompt enhancement look like a normal assistant reply, stream the rewritten prompt, and open general settings without selecting a path.

**Architecture:** Decode only the `rewritten_prompt` JSON string while llama.cpp generates it. Thinking and prompt deltas update independent observable text views; the complete validated result remains the only trigger for image inference. Give the settings header initial focus without changing click-to-edit or keyboard navigation. Native UI checks use a stable app and fixture workspace in the user's cache directory, with no access to Documents or production settings.

**Tech Stack:** SwiftUI/AppKit, Python incremental JSON-string parsing, existing subprocess supervision and native regression checks.

1. Add chunk-boundary, JSON-escape, early-stream, incomplete-output and cancellation checks. Implement rewritten-prompt deltas and final validation reconciliation.
2. Remove the enhancement reply's outer card, align its header with ordinary replies, and left-align the “显示思考内容” toggle. Render prompt deltas in an isolated text view and preserve conversation scrolling.
3. Fix settings presentation focus; check repeated sheet opening, unselected paths, explicit editing, outside clicks and keyboard navigation.
4. Prepare a stable cache-based native UI fixture. Verify the real UI, replay actual T2I/I2I output and run a real enhancement stream. Run the relevant automated checks and build/package validation.
5. Commit and push to main, verify the exact Actions run and latest downloadable release.

## Verification

- Python checks: 36 passed, including split JSON escapes, supplementary Unicode, early prompt visibility, malformed/truncated results, both enhancement modes and cancellation while rewriting.
- App state checks verified isolated prompt updates, result reconciliation and restored partial replies. Native layout checks verified streamed growth, reading older replies, returning to the bottom just before completion, image actions and composer growth.
- General settings opens without selecting a path on both first launch and repeated sheet presentation; explicit editing and keyboard navigation still work. Editor, scrollbar and inspector checks passed.
- Replayed actual T2I, I2I and three-reference outputs across UTF-8 chunk boundaries. A real T2I run produced 130 prompt deltas whose combined text exactly matched its validated 2,704-character result.
- The native UI fixture launched from Library/Caches without a protected-folder permission prompt. Visual checks covered the plain message layout, left-aligned disclosure, progressive prompt display and neutral settings focus.
