---
name: release-notes
description: Turn a description of what shipped into clean release notes / a changelog, and save them as a versioned artifact. Use when the user asks for release notes, a changelog, or a written summary of what changed in a release.
---

# Writing release notes

Turn a short description of what shipped into clear, human release notes, then save them as an artifact
so they outlive the turn.

## Steps

1. **Write `NOTES.md`** in your workspace (via the Write tool). Structure it:
   - A title line with the version, e.g. `# v1.2`.
   - A short **Features** list and a short **Fixes** list — one plain, user-facing bullet each.
   Keep it tight; no filler, and never invent items beyond what you were told shipped.
2. **Save it.** Call `save_artifact` with the file's path (`NOTES.md`) so the notes become a versioned
   deliverable that outlives the turn.

Write the file first, then save — `save_artifact` reads it from your workspace.
