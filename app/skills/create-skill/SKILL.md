---
name: create-skill
description: Author a new skill (or revise an existing one) and promote it into the skill store. Use this whenever the user wants to create, build, write, edit, or improve a skill — even if they don't say the word "skill" explicitly but describe teaching you a reusable capability, workflow, or way of producing a deliverable.
---

# Create Skill

Author a skill — a folder the runtime stages into every future turn so the whole team inherits a capability — and promote it into the store. A skill is **capability**, not conversation: it captures *how* a deliverable is built and the boilerplate it starts from, so the system prompt can stay generic.

## What a skill is

```
<slug>/
├── SKILL.md          (required)
│   ├── YAML frontmatter: name, description (both required)
│   └── Markdown instructions
└── (optional supporting files)
    ├── references/   docs the agent reads as needed
    └── assets/       templates/fixtures used in the output
```

The **slug is the folder name** (kebab-case). The frontmatter `name` is the display name; the `description` is the *primary trigger* — it decides when the skill fires, so write it to say both **what** the skill does AND **when** to use it, and lean slightly pushy (skills tend to under-trigger).

## How to build one

1. **Capture intent.** Nail down: what should this skill let you do, when should it trigger, and what does its output look like? If the current conversation already contains the workflow the user wants captured, extract it from there and confirm before writing.
2. **Write the folder in your workspace.** Create `<slug>/SKILL.md` with the frontmatter and imperative instructions. Keep SKILL.md focused (aim under ~500 lines); push long material into `references/` files and point to them. Prefer explaining *why* a step matters over heavy-handed "MUST".
3. **Review with fresh eyes.** Re-read the draft as if you'd never seen it. Is the description specific about triggering? Are the steps unambiguous?
4. **Promote it.** Call `save_skill` with the folder's workspace-relative path:

   `save_skill(folder_path: "<slug>")`

   This requires the user's approval — a promoted skill steers every future turn, so the human confirms. On approval the folder becomes the tenant's current version of that skill; re-running `save_skill` on the same slug promotes a new version (history is kept).

## Writing the description well

The description is the whole trigger. Compare:

- Weak: `How to write release notes.`
- Strong: `Write release notes from a set of merged PRs. Use this whenever the user asks for release notes, a changelog, or a "what changed" summary for a version — even if they only paste PR titles.`

State the capability and enumerate the contexts/phrasings that should fire it.

## After promoting

Summarize what you built for the user — the slug, the display name, and one line on when it will trigger — so they know what just entered the store.
