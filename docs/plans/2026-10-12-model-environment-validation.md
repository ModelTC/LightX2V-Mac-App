# Model Environment Validation Implementation Plan

**Goal:** Bundle the revised user requirements and make model checks enforce the same minimum dependency versions as environment discovery.

**Architecture:** Reuse `PythonEnvironmentSearch.probe` and `PythonEnvironment.isCompatible` before starting the existing bridge model check. This keeps package versions, architecture and MPS eligibility in one implementation. Retain the existing model/config validation, real MPS operation and LightX2V import. The app owns and cancels both phases during termination.

**Tech Stack:** Swift concurrency, existing Core environment probe, native process runner, Python bridge.

1. Copy `/Users/yongyang/Documents/x2v/requirements.txt` byte-for-byte into the bundled resource.
2. Add regression checks for each outdated/missing package, exact/newer versions, MPS rejection, model-check failure and cancellation between phases.
3. Make `AppStore.checkEnvironment` run the shared environment probe before the model bridge, without enabling generation until both phases pass.
4. Run setup checks, native app-state checks and Python integration checks. Build and verify bundled requirements.
5. Commit and push the authorized main branch; verify the automatic build and latest release match the commit.

**User clarification:** Keep manual installation independent of environment managers and workspace paths. The help sheet and installation document use the user's ten pip commands, preceded only by a Python 3.11 introduction and followed by the search-again instruction. Automatic installation continues to use the revised bundled requirements.

## Real installation and inference verification

The user requested a complete verification after intentionally removing dependencies. Exercise the production settings flow in the current workspace (`/Users/yongyang/Documents/x2v/ws4`), without resetting its existing history or locator.

1. Launch the rebuilt APP, search local environments, and verify missing/outdated environments cannot be selected. Inspect and copy the manual guide.
2. Choose automatic installation, use the bundled revised requirements, and verify all installation stages and logs. Search again, select `TorchLightX2V`, save, and pass the shared dependency/model check.
3. Run real t2i and i2i with enhancement disabled and enabled, using the new environment. Verify thinking/prompt streaming, image completion, input/output dimensions, and same-conversation history.
4. Verify result copy, Finder reveal, references (including repeated references), image paste, scrolling, and state after relaunch. Retain test outputs and logs locally.
5. Run the required automated checks, commit/push the final changes, and verify CI and the permanent latest release.

## Validation

- Each of the four missing/outdated dependencies is rejected identically by search and model checking. Exact/newer versions pass; MPS and architecture failures stop before the model bridge.
- A failed model import cannot mark a qualifying environment ready. Closing the app cancels a pending probe and prevents launching the model bridge.
- Full native app-state checks, 9 setup checks and 36 Python integration tests passed.
- Automatic installation completed in the production APP. All 56 pinned requirements match the revised file; imports, `pip check` and a real MPS operation passed.
- Signed app/package checks passed; the source and packaged dependency resources match the user's file byte-for-byte.

## Completed production checks

- Discovery rejected the existing missing/outdated environments. Automatic installation created Python 3.11.17 `TorchLightX2V`; searching again exposed it as selectable, and the model check passed. Selecting the older Transformers 4.57.3 environment produced the same minimum-version error as discovery.
- The manual guide rendered all ten commands and copied them correctly. Reopening the APP retained the installed environment and history, while model selection reset to empty and references remained disabled until a model was selected.
- Real inference used the new environment in every case:

| Case | Prompt enhancement | PNG dimensions | Result |
| --- | --- | --- | --- |
| t2i | Off | 1024 × 1024 | Completed |
| i2i | Off | 896 × 1184 | Completed |
| t2i | On | 1248 × 832 | Completed; enhancement supplied 3:2 |
| i2i | On | 896 × 1184 | Completed; `<image1>` supplied 52:69 |

- Thinking streamed and could be hidden/reopened; it collapsed automatically before the final enhanced prompt. The t2i enhanced prompt was observed streaming before image inference started. Copy, image paste, Finder reveal, repeated references and composer/bottom scrolling were exercised in the production APP. Cancelling image inference and enhancement stopped their processes.
- The user then requested stopping further tests and submitting the changes. The last generation had already completed; no generation remained active. No additional test runs were started. Outputs and installation/inference logs remain in the local workspace.
