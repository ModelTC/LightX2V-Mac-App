# Explicit model selection per launch

- Start every AppStore session with no selected model. Keep persisted model/config paths and history, but never persist the selected model or expanded sections.
- Show “选择模型” in the composer menu; Qwen-Image-2.1 remains the only available model.
- Keep both inspector headers visible but collapsed and disabled until a model is selected. Selection opens the inspector and both sections with a short, Reduce Motion-aware transition. After selection, allow independent manual collapse and re-expansion.
- Defer the existing automatic environment check until selection. Guard generation and model checks against an empty model, including keyboard/menu entry points. New creations and history reuse keep the current session selection; neither silently selects a model on a fresh launch.
- Generalize the empty-history message to “生成的作品会保存在这里” and avoid showing a selected-model summary in the empty composer state.
- Verify an existing configured workspace reopening empty, disabled send before selection, menu selection and automatic expansion, independent toggles, same-model reselection, and reopening after selection. Confirm saved paths/history are unchanged.

## Verification

- Release build and native prompt/input regression checks passed.
- Tested a separate app bundle with an isolated, already-configured workspace: launches with no selected model and both sections collapsed; entering a prompt and pressing Return leaves the draft intact and sending disabled.
- Confirmed the menu contains only Qwen-Image-2.1; choosing it reveals both sections with the saved paths and 1K / 1:1 defaults. Both sections collapse independently. Reselecting the model reopens them, including after hiding the inspector.
- New creation retains the current session's model. Closing and reopening the app restores an empty selection and collapsed sections; selecting again restores the saved model/config paths.
- Compared the entire saved workspace JSON before and after the interaction: identical, with no selected model or section state persisted. The fixture's intentionally absent model directory produces the expected validation message without launching inference.
