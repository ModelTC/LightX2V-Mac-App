# Enhancement Defaults

Enable Prompt enhancement in new configurations. Show thinking content initially for each enhancement reply, including reopened history. Both switches remain manually controllable; saved explicit enhancement choices are preserved.

1. Update the configuration and message defaults without changing inference or streaming.
2. Verify default enhancement submission and persistence of manual disabling. Keep ordinary-inference fixtures explicitly disabled.
3. Check visible thinking streams, conversation scrolling, and manual disclosure in the cache-based UI fixture.
4. Build, commit, push, and verify the exact CI run and latest release.

## Verification

- Core and enhancement state checks pass: default submission enhances first; explicit disabling still persists across relaunch.
- Native conversation checks pass with thinking visible: its internal text can grow without resizing or shifting the conversation; completed image actions, references and reopened history remain anchored correctly.
- The cache-based UI fixture confirms both switches start on, each reply can hide its thinking independently, and a later reply starts with thinking visible. The signed release app builds successfully.
