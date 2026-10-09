# Contained inspector disclosure animation

- Replace the upward insertion/removal transition with a clipped height reveal. Keep content at its natural height and top alignment throughout; animate only its viewport height and opacity over 240 ms, without bounce.
- Keep each title outside the animated region. Keep separators in stable positions or inside the same clipped region as their content. Move the window's 28 pt top inset outside the inspector scroll view and clip the viewport.
- Scope animation to the two section bodies and disclosure chevrons, including automatic expansion on model selection. Avoid applying an animation transaction to the entire model-selection action.
- Keep collapsed controls hidden from accessibility, hit testing, and keyboard interaction. Preserve input state during disclosure changes and respect Reduce Motion.
- Verify intermediate reveal sizes, dynamic content height, adjacent header boundaries, rapid reversals, and collapsed/reopened UI states. Use an isolated app workspace, without inference or changes to user settings.

## Verification

- Added 80 rendered boundary assertions using the production reveal: two widths, two content heights, and ten progress values including reversal sequences. Check both neighboring headers and every visible content row for overflow. Included the check in macOS CI.
- In the isolated app, verified initial model selection, each section independently collapsing, rapid triple clicks on each header, and both sections collapsed. The previously selected 2K / 16:9 parameters remain intact after reopening.
- Inspected full-size and minimum-height window layouts; the reserved top inset and section headers remain clear. Collapsed controls are absent from the accessibility tree.
- Release build passed. No model inference or user workspace changes were required.
