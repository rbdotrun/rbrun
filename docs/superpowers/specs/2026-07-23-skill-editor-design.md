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

**The versioned archive is the single source of a skill's content.** A skill's content _is_
`SkillVersion.archive` — a gzipped-tar **blob in rbrun's DB**. `SKILL.md` (name, description, and the
authored card/metadata) lives _inside_ that archive. Therefore:

- The preview **DERIVES** the card + `preferred_skills` + `preferred_tools` by **parsing the selected
  version's `SKILL.md` frontmatter** — a plain DB read. It is **version-accurate by construction**:
  the dropdown at v3 shows v3's card exactly as authored then.
- We **never copy** archive-derived fields into columns on `Skill`. A column would be a second source
  of truth that drifts and only reflects `current_version` — breaking the version dropdown. (insitix
  copies frontmatter → columns because its _data DB is trashed on pull_; rbrun's DB is the truth, so we
  do NOT import that shape.)
- Files only **seed** the DB. Nothing is read from disk at render time.

The only thing that is _not_ in the archive — because it can't be — is **`SkillScenario`**: a runnable
case for the skill (a seeded prompt, optional steps, and a pointer to the artifact its run produced).
It is its own DB row; it _is_ the truth for what it holds.

**Examples ARE scenarios.** An "example" is not a hand-attached artifact — it is *what the skill
produces when you run it*, which is exactly what a scenario does. So the two collapse into one concept:
a scenario, when run (`SkillScenarioRun`), self-validates _if it has steps_ AND captures the artifact
the run yielded — that artifact is the showcase. There is no separate `SkillExample`.

## What already exists (reuse)

- `Skill` + `SkillVersion` (immutable, digest-addressed, `current_version`, `promote!`) — the history.
- `SkillArchive` (folder ⇄ blob, `files`, `pack_files`, `digest_files`) + a frontmatter reader pattern
  (in `SkillScenarios`/`SkillSeeder`).
- `SkillScenario` (belongs_to skill; `prompt` + `steps: [{label, description}]`) — the workflow steps.
- **`ArtifactVersion`** (Plan C) — the unlock that lets a scenario run capture a real produced artifact
  as its showcase.
- **`SkillScenario`** + **`SkillScenarioRun`** (Plan B) — the runnable case + its self-validating runner;
  the editor reuses both (the runner now also captures the produced artifact).
- `SkillScenarios.ingest` — reads a folder's `scenarios/*.yml` → `SkillScenario` rows.
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

`create-skill` only ever built _from scratch_ (empty workspace). To _edit_, the agent needs the real
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

| Section                                                | Source                                                        |
| ------------------------------------------------------ | ------------------------------------------------------------- |
| Card: icon (gradient hero), name, tagline, description | parse the selected version's `SKILL.md` frontmatter          |
| preferred_skills / preferred_tools (soft-hint chips)   | parse the selected version's frontmatter                     |
| Workflow steps                                         | a `SkillScenario`'s `steps` (when it has them)               |
| Examples: prompt → the artifact it yields              | `SkillScenario` → `showcase_artifact_version` (from its run) |

(Workflow steps and examples are the **same rows** — a scenario with steps shows its checklist; a
scenario whose run produced an artifact shows that artifact. Both come from `SkillScenario`.)

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

## `SkillScenario` gains a showcase artifact (no separate `SkillExample`)

Rather than port `MarketplaceSkillExample`, we extend the scenario we already have — a scenario IS the
example. Two changes to `SkillScenario`:

- `steps` becomes **optional** — with steps: a self-validating dogfood; without: a pure showcase run.
- add **`showcase_artifact_version_id`** (FK → `rbrun_artifact_versions`, nullable) — the artifact the
  scenario's last run produced. This is a curated *pointer* (not archive content, so no invariant
  issue). `SkillScenarioRun` sets it when the run produced an artifact — and artifacts already survive
  the run's reaping (the completion→message FK nullifies), so the showcase persists after the box dies.

The preview's "examples" render `scenario.prompt` over `scenario.showcase_artifact_version` (itself
versioned — re-running yields a new `ArtifactVersion`, the `v2 ▼` on the showcase).

### Two steps: author, then run

1. **Author (agent).** While editing the skill the agent writes `scenarios/*.yml` in the folder
   (`prompt`, optional `steps`). `save_skill` now **also ingests** those into `SkillScenario` rows
   (via `SkillScenarios.ingest` — today only the dogfood rake does this; the editor needs it inline).
   An example starts as a prompt with **no result**.
2. **Run (user).** Each example in the preview has a **▶ Run** action → enqueues `SkillScenarioRun` →
   the skill runs on that prompt, self-validates if it has steps, and its produced artifact is captured
   into `showcase_artifact_version`. The example fills in with the real result; re-running adds a
   version. The user decides when to spend a real run — nothing runs on its own.

## Plans (one spec, three plans, build in order)

- **Plan 1 — the editor + version-aware card.** `editing_skill_id` on Session; the New dialog + stub
  creation; `skills/:slug/edit` two-panel view; stage-current-version-on-open; `SkillCard.from(version)`
  (name/tagline/icon/description) + version dropdown; the `skills/preview` component. Delivers a working
  editor whose card preview is version-accurate and updates on promote. Retires the create-skill drawer.
- **Plan 2 — preferred + steps.** Extend `SkillCard` to `preferred_skills`/`preferred_tools` (chips);
  render a scenario's `steps` (its workflow checklist) in the preview.
- **Plan 3 — showcase (examples).** `save_skill` ingests the folder's `scenarios/*.yml` on promote;
  make `SkillScenario.steps` optional + add `showcase_artifact_version_id`; `SkillScenarioRun` captures
  the run's produced artifact into it; the preview renders each scenario as `prompt · ▶ Run`, and after
  a run as `prompt → showcase artifact` (versioned). Running is user-triggered, one scenario at a time.

## Non-goals (deferred)

- Runtime injection of a skill's `preferred_skills`/`preferred_tools` as soft hints (display only here).
- Direct-edit fields on the right (it is pinned to preview; the conversation is the editor).
- A marketplace / publishing surface, `Skill.kind`, favoriting.
- Per-version scenarios (a `SkillScenario` belongs to the skill, not a version) — reconsider later.
- Auto-running scenarios (runs are always user-triggered, one at a time — the board rake stays for batch).

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
  yields the label as name; a scenario's `showcase_artifact_version` association + tenancy.
- Controller: New dialog creates a stub skill (v1 present) and redirects to the editor; the editor stages
  the current version into the session workspace; the version dropdown renders each version's own card.
- Flow: promoting a new version (via `save_skill`) adds it to the dropdown and re-renders the card
  (broadcast).
- Dogfood: open the editor on a seeded skill, a real turn edits `SKILL.md` (tagline) and promotes; assert
  a new version exists and its parsed tagline changed.
