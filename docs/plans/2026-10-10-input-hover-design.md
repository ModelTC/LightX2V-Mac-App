# Match path input feedback to its editing area

The previous whole-row hover included padding, icon and chooser, while the text cursor belonged only to the narrow TextField. Use one padded editable surface for icon, text and whitespace; keep the chooser outside it.

The native input boundary drives both highlight and cursor, including before focus. Clicking the padded area focuses the TextField. Button feedback remains independent. Preserve native text selection, keyboard focus, disabled state, scrolling and Reduce Motion.

Check both focused and unfocused inputs at every edge, padded corners, chooser, blank space, disabled/hidden state, and leaving the window; run the existing native input and scrollbar regression checks and release build.
