# Skill editor — two-panel, version-aware preview — design

**Date:** 2026-07-23
**Status:** design (one spec, three implementation plans)

## Purpose

A dedicated view for authoring and editing a skill: **conversation on the left** (the only editor — you
change the skill by talking to the agent), a **live, version-aware preview on the right** (pinned to
"preview" — a fancy inventory representation of the skill). Creating a skill is "name it, land in the
editor"; the same editor serves new and existing skills.

This replaces the create-skill **drawer** (the conversation now lives in the editor's left panel).

## The load-bearing invariant

**The versioned archive is the single source of a skill's content.** A skill's content *is*
`SkillVersion.archive` — a gzipped-tar **blob in rbrun's DB**. `SKILL.md` (name, description, and the
authored card/metadata) lives *inside* that archive. Therefore:

- The preview **DERIVES** the card + `preferred_skills` + `preferred_tools` by **parsing the selected
  version's `SKILL.md` frontmatter** — a plain DB read. It is **version-accurate by construction**:
  the dropdown at v3 shows v3's card exactly as authored then.
- We **never copy** archive-derived fields into columns on `Skill`. A column would be a second source
  of truth that drifts and only reflects `current_version` — breaking the version dropdown. (insitix
  copies frontmatter → columns because its *data DB is trashed on pull*; rbrun's DB is the truth, so we
  do NOT import that shape.)
- Files only **seed** the DB. Nothing is read from disk at render time.

The only things that are *not* in the archive — because they can't be — are **`SkillScenario`** (seeded
step rows) and **`SkillExample`** (a pointer to a real `ArtifactVersion`). Those are their own DB rows;
they *are* the truth for what they hold.

## What already exists (reuse)

- `Skill` + `SkillVersion` (immutable, digest-addressed, `current_version`, `promote!`) — the history.
- `SkillArchive` (folder ⇄ blob, `files`, `pack_files`, `digest_files`) + a frontmatter reader pattern
  (in `SkillScenarios`/`SkillSeeder`).
- `SkillScenario` (belongs_to skill; `prompt` + `steps: [{label, description}]`) — the workflow steps.
- **`ArtifactVersion`** (Plan C) — this is the unlock that lets us finally port `SkillExample`.
- `save_skill(folder_path:)` (packs a workspace folder → promotes a version, gated) + `reload_skills`
  (stages DB → `<workspace>/.claude/skills/…`) + per-session `preferred_skills` steer + the live
  single-row broadcast muscle + the app-wide `#modal` dialog + `solid_cable` realtime.
- The `table`, `drawer`, `surface`, `empty`, `turn_footer` primitives.

## The editor

### Route & layout

- `GET skills/:slug/edit` — the two-panel editor (full view, not a drawer):
  - **Left:** the conversation for the session bound to this skill (reusing `Sessions::Default`).
  - **Right:** the version-aware preview (below).
- Existing skill: the index row links here. New skill: the dialog lands here (below).

### New = name it, then edit

- The Skills index **New** button opens the app-wide `#modal` dialog with **one field: a label**.
- Submit → create the `Skill` (`slug` from the label) **with a stub v1**: `promote!` a minimal archive
  whose `SKILL.md` is `---\nname: <label>\ndescription: …\n---\n<placeholder body>`, `source: :ui`. The
  stub guarantees a `current_version` to stage and a v1 for the dropdown.
- Redirect to `skills/:slug/edit`.

### Editing an existing skill (the flow create-skill never did)

`create-skill` only ever built *from scratch* (empty workspace). To *edit*, the agent needs the real
folder in front of it:

1. Opening the editor find-or-creates a session **bound to the skill** (`rbrun_sessions.editing_skill_id`,
   optional FK — one editor session per skill, reused across page loads).
2. Before the first turn, the skill's **current version is materialized into the session's workspace**
   (`SkillArchive.unpack` the `current_version.archive` into `<workspace>/<slug>/`) so the agent opens
   the real current `SKILL.md`. (Same DB→workspace direction as `reload_skills`, scoped to this skill.)
3. The session carries `preferred_skills: ["create-skill"]` so the agent is steered by the authoring
   guidance.
4. The conversation modifies the folder → `save_skill(folder_path: "<slug>")` promotes a new
   `SkillVersion` → the preview broadcasts (new version in the dropdown, card re-renders).

## The right preview (version-aware, derived)

A **version dropdown** (from `skill.versions`, newest first — digest short + `source` + timestamp,
artifact-versioning style) selects the version everything below renders from. Selecting a version
re-renders the panel (a Turbo frame keyed on the version). Every field is **derived from the selected
version's archive** or a DB relation:

| Section | Source |
|---|---|
| Card: icon (gradient hero), name, tagline, description | parse the selected version's `SKILL.md` frontmatter |
| preferred_skills / preferred_tools (soft-hint chips) | parse the selected version's frontmatter |
| Workflow steps | `SkillScenario.steps` for the skill |
| Examples: prompt → the artifact it yields | `SkillExample` → `ArtifactVersion` |

Composed entirely with `component(...)` / `custom(...)` — a `skills/preview` folder component, no raw
markup.

### Frontmatter the preview reads

`SKILL.md` frontmatter keys the preview parses (line-by-line, the way the SDK reads them — a value may
carry a colon), from the selected version's archive:
`name`, `description`, `tagline`, `icon`, `preferred_skills` (list), `preferred_tools` (list). A
`Rbrun::SkillCard.from(version)` value object does the parse + exposes `name/tagline/icon/description/
preferred_skills/preferred_tools`. It reads `SkillArchive.files(version.archive)["SKILL.md"]` — DB only.

> **preferred_skills / preferred_tools are DISPLAY here.** Wiring them as actual runtime soft-hints
> (injected when the skill is active, like the session `preferred_skills` steer) is a **follow-up**, not
> this view.

## New model — `Rbrun::SkillExample`

Ported from insitix's `MarketplaceSkillExample`, now possible because `ArtifactVersion` exists.

Columns: `tenant` (Tenanted), `skill_id` (FK → `rbrun_skills`), `artifact_version_id`
(FK → `rbrun_artifact_versions`), `user_prompt` (text, required), `label` (required), `description`.

`belongs_to :skill`, `belongs_to :artifact_version`. The example = "this prompt yields this artifact."

## Plans (one spec, three plans, build in order)

- **Plan 1 — the editor + version-aware card.** `editing_skill_id` on Session; the New dialog + stub
  creation; `skills/:slug/edit` two-panel view; stage-current-version-on-open; `SkillCard.from(version)`
  (name/tagline/icon/description) + version dropdown; the `skills/preview` component. Delivers a working
  editor whose card preview is version-accurate and updates on promote. Retires the create-skill drawer.
- **Plan 2 — preferred + steps.** Extend `SkillCard` to `preferred_skills`/`preferred_tools` (chips);
  render `SkillScenario.steps` in the preview.
- **Plan 3 — examples.** `SkillExample` model + migration; render examples (prompt → the artifact) in
  the preview; a minimal path to register an artifact the conversation produced as an example.

## Non-goals (deferred)

- Runtime injection of a skill's `preferred_skills`/`preferred_tools` as soft hints (display only here).
- Direct-edit fields on the right (it is pinned to preview; the conversation is the editor).
- A marketplace / publishing surface, `Skill.kind`, favoriting.
- Per-version `SkillScenario`/`SkillExample` (they belong to the skill, not a version) — reconsider later.

## Invariants respected

- **Archive is the only source of a skill's content** — the preview derives card/preferred metadata from
  the selected version's archive; never a column. Files only seed.
- **DB is the source of truth** — editing writes new `SkillVersion`s; the workspace is staged from the
  DB, never the reverse-as-truth.
- **Compose primitives** — the preview and dialog are `component(...)`/`custom(...)`, never raw markup.
- **Gated promote** — `save_skill` stays `needs_approval!` (a promoted skill steers every future turn).
- **Live per-row broadcast** — promote streams the new version into the dropdown/preview, no full repaint.

## Testing

- Model/service: `SkillCard.from(version)` parses each frontmatter key from an archive; a stub-v1 skill
  yields the label as name; `SkillExample` associations + tenancy.
- Controller: New dialog creates a stub skill (v1 present) and redirects to the editor; the editor stages
  the current version into the session workspace; the version dropdown renders each version's own card.
- Flow: promoting a new version (via `save_skill`) adds it to the dropdown and re-renders the card
  (broadcast).
- Dogfood: open the editor on a seeded skill, a real turn edits `SKILL.md` (tagline) and promotes; assert
  a new version exists and its parsed tagline changed.
