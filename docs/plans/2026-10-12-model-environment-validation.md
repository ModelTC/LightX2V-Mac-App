# Model Environment Validation Implementation Plan

**Goal:** Bundle the revised user requirements and make model checks enforce the same minimum dependency versions as environment discovery.

**Architecture:** Reuse `PythonEnvironmentSearch.probe` and `PythonEnvironment.isCompatible` before starting the existing bridge model check. This keeps package versions, architecture and MPS eligibility in one implementation. Retain the existing model/config validation, real MPS operation and LightX2V import. The app owns and cancels both phases during termination.

**Tech Stack:** Swift concurrency, existing Core environment probe, native process runner, Python bridge.

1. Copy `/Users/yongyang/Documents/x2v/requirements.txt` byte-for-byte into the bundled resource.
2. Add regression checks for each outdated/missing package, exact/newer versions, MPS rejection, model-check failure and cancellation between phases.
3. Make `AppStore.checkEnvironment` run the shared environment probe before the model bridge, without enabling generation until both phases pass.
4. Run setup checks, native app-state checks and Python integration checks. Build and verify bundled requirements.
5. Commit and push the authorized main branch; verify the automatic build and latest release match the commit.

## Validation

- Each of the four missing/outdated dependencies is rejected identically by search and model checking. Exact/newer versions pass; MPS and architecture failures stop before the model bridge.
- A failed model import cannot mark a qualifying environment ready. Closing the app cancels a pending probe and prevents launching the model bridge.
- Full native app-state checks, 9 setup checks and 36 Python integration tests passed.
- pip dry-run resolved all 57 dependencies in the revised file without installing packages into the user's environment.
- Signed app/package checks passed; the source and packaged dependency resources match the user's file byte-for-byte.
