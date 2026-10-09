# General settings guide

- Keep the three settings visible and editable; guide users in workspace → source → Python order.
- Mention automatic download in the source input placeholder and remove the two footer explanations.
- Highlight the first unfinished step with a neutral card outline and an animated leading marker. Show compact completion progress in the header. Bring the next step into view in small windows. Respect Reduce Motion.
- Validate paths using the same rules as Save. Refresh the guide after Return, blur, a file selection, a successful download, or an environment selection, not on every keystroke. Do not move keyboard focus.
- Reopening completed settings shows completion immediately. Clearing or invalidating a committed path returns guidance to that step. “已填写” indicates path validity, not a successful PyTorch/MPS probe.
- Verify ordered/out-of-order completion, invalid paths, clearing, reopening, and native input hover/cursor regressions; inspect the isolated first-launch UI, build, then publish.

## Verification

- 6 setup check groups and 8 core check groups passed.
- 128 native input/editor/scrollbar checks passed, including actual TextField draft, blur, and Return behavior.
- Isolated APP: 0 → 1 → 2 → 3 progress, successful Save, reopening at 3/3, clearing source returns to step 2. Final layout brings step 3 fully into view without moving keyboard focus.
- Apple Silicon release build and signature verification passed. Existing user settings were not modified.
