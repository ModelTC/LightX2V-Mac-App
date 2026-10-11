# Enhancement Card and Thinking Disclosure

Remove the image-generation memory/loading hint. Reduce the inspector's Prompt enhancement card to a single row: title, configuration button, and switch. Keep configuration accessible when enhancement is off; validate missing resources in the configuration sheet and before submission.

Thinking starts visible for a live thinking reply and automatically closes when that phase ends. Completed history starts collapsed, without a flash of expanded content. Users can reopen any reply's thinking; subsequent prompt/image completion must preserve that manual choice. Retain all thinking text and prompt streaming.

1. Update the two views and phase-driven disclosure state.
2. Verify automatic collapse and bottom anchoring in the native conversation checks.
3. Use the stable cache-based app fixture to check the card with enhancement on/off, thinking/rewrite/completion transitions, manual reopening, and restored history.
4. Build, commit, push, and verify the exact automated build and latest package.

## Verification

- Native conversation checks pass: thinking closes before prompt streaming, bottom anchoring remains correct, and completed history opens collapsed.
- The cache-based app confirms the single-row card, working configuration while enhancement is off, initial thinking visibility, automatic closure, and manual reopening during prompt streaming that survives image completion.
- The generation loading hint is removed, the signed release app builds, and the completed image's action icons remain visible in the actual UI.
