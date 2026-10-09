# Pointer and hover feedback

- Restore the arrow after leaving an active path input, including buttons and blank space. Reconcile after AppKit dispatch so the native field editor cannot leave a stale I-beam behind.
- Preserve the I-beam over other editable/selectable text, clipped input bounds, text selection dragging, and native sheets. Do not steal focus when merely moving the pointer.
- Use 140 ms gray surface and border transitions on interactive rows, icons and buttons. Avoid movement, scaling and decorative effects. Preserve red ratio selection and disabled states; respect Reduce Motion.
- Verify native cursor boundaries (four edges, other inputs, disabled/hidden inputs, scrolling, drag release and window changes), existing prompt/scrollbar checks, and isolated first-launch/main-window layouts before publishing.
