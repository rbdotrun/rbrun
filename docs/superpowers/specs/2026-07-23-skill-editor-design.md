# Skill editor — a form — design

**Date:** 2026-07-23
**Status:** design (one spec, two implementation plans)

## Purpose

A plain **form** to author and edit a skill — no AI, no preview panel, no conversation. You fill in the
skill's identity, instructions, soft-hints, and scenarios; **Save** assembles `SKILL.md` and **promotes
a new `SkillVersion`**. Creating a skill is "name it, land in the form." The form is the whole editor.

(This supersedes the earlier two-panel conversation+preview idea and the create-skill drawer.)

## The load-bearing invariant

**The versioned archive is the single source of a skill's content.** A skill's content _is_
`SkillVersion.archive` — a gzipped-tar **blob in rbrun's DB**; `SKILL.md` (name, description, card,
soft-hints) lives _inside_ it. So:

- **Save** takes the form fields, **assembles a `SKILL.md`** (frontmatter + body), packs the folder, and
  `promote!`s a new `SkillVersion` (`source: :ui` — the "future in-UI edit" the model always anticipated).
- **Load** (opening the form, or picking a past version) **parses `SKILL.md` from that version's archive**
  to fill the fields — a plain DB read, version-accurate.
- We **never** add card/soft-hint **columns** on `Skill`. The archive is the truth; a column would be a
  second one that drifts and only reflects `current_version`. (insitix copies frontmatter → columns
  because its data DB is trashed on pull; rbrun's DB is the truth — we do NOT import that shape.)

The only things not in the archive are DB rows in their own right: **`SkillScenario`** (a runnable
case) and its **produced artifact** (`ArtifactVersion`). Those are their own truth.

## What already exists (reuse)

- `Skill` + `SkillVersion` (immutable, digest-addressed, `current_version`, `promote!`).
- `SkillArchive` (`files`, `pack_files`, `digest_files`) + a line-by-line frontmatter reader pattern.
- `SkillScenario` (belongs_to skill; `prompt` + `steps` jsonb + `attachments`).
- `SkillScenarioRun` (auto, self-validating) — seeds a `Rbrun::Workflow` from `scenario.steps`, runs the
  skill, self-validates each step (auto mode auto-approves `validate_step`).
- `ArtifactVersion` (Plan C) — a scenario run's produced artifact = the showcase.
- The `table`/`surface`/`empty`/`field`/`input`/`textarea`/`select`/`multi_select` primitives + live broadcast + `solid_cable`.

## The form

### Routes — vanilla resourceful

`resources :skills, param: :slug, only: %i[index new create edit update]` (+ the existing `reconcile`):

- `GET  skills/new`        — a blank form.
- `POST skills`            — create: assemble `SKILL.md` → create `Skill` + `promote!` v1.
- `GET  skills/:slug/edit` — the form loaded from the current version (or `?version=<id>`).
- `PATCH skills/:slug`     — update: assemble `SKILL.md` → `promote!` a new version.

No dialog, no stub — **New is just the empty form**; you fill it (the label/name is a field) and submit
→ the skill is created with v1 assembled from what you typed. Standard Rails `new`/`create`/`edit`/`update`.

### Fields (all authored, all end up in `SKILL.md`)

- **Identity / card:** `name`, `label`, `tagline`, `icon`, `kind`, `example` (a "what to ask" hint).
- **Description:** `description` (frontmatter).
- **Instructions:** the `SKILL.md` **body** (a textarea).
- **Soft hints:** `preferred_skills` (multiselect of existing skill slugs), `preferred_tools`
  (multiselect of tool names). Display + authored only here; runtime injection is a non-goal.

On **Save**: build the frontmatter from the fields + append the body → one `SKILL.md` → `pack_files` →
`digest_files` → `Skill#promote!(source: :ui)`. A `Rbrun::SkillForm` service does assemble/parse in one
place (the inverse pair: fields ⇄ `SKILL.md`). Version dropdown loads any version's archive into the form.

### Scenarios (a sub-form)

Each scenario row edits a `SkillScenario`: `label`, `prompt`, and **optional** `steps` (repeatable
`{label, description}` rows saved as the `steps` **jsonb**). Steps are the workflow the skill should
produce; empty = a pure showcase.

- **▶ Run** enqueues `SkillScenarioRun` (auto, self-validating). It seeds a `Rbrun::Workflow` from the
  jsonb steps, runs the skill in a `kind: :skill_scenario` session, self-validates each step, and
  captures the produced artifact into the scenario's **showcase**.
- After a run: show the verdict (steps done/total) + the produced artifact (versioned — re-run adds a
  version). Runs are user-triggered, one at a time.

## Model additions

- **`rbrun_sessions.kind`** — enum `{ user: "user", skill_scenario: "skill_scenario" }`, default
  `"user"`, not null. `SkillScenarioRun` sessions are `:skill_scenario` (ephemeral, machine-driven,
  self-validating); everything else is `:user`. The **conversation index filters to `:user`** so
  scenario runs don't pollute it. (`kind` is the durable "what is this session"; `auto` stays the
  runtime lever.) Enum kept open for future kinds.
- **`rbrun_skill_scenarios.showcase_artifact_version_id`** — FK → `rbrun_artifact_versions` (nullable):
  the artifact the scenario's last run produced. A curated *pointer* (not archive content). Set by
  `SkillScenarioRun` when the run produced an artifact; artifacts already survive the run's reaping (the
  completion→message FK nullifies).
- `SkillScenario.steps` — already jsonb defaulting `[]`; the form treats it as **optional**.

No `SkillExample`, no `editing_skill_id`, no card/soft-hint columns.

## Plans (one spec, two plans, build in order)

- **Plan 1 — the skill form + versions.** `Rbrun::SkillForm` (fields ⇄ `SKILL.md`: name/label/tagline/
  icon/kind/example/description/body + `preferred_skills`/`preferred_tools`); vanilla `new`/`create`/
  `edit`/`update` (create → v1, update → `promote!` a new version); the version dropdown (load a version's
  archive into the form). `rbrun_sessions.kind` enum + index filter. Delivers full skill editing.
- **Plan 2 — scenarios + run.** The scenarios sub-form (label/prompt/steps jsonb); `save_skill`-style
  ingestion isn't needed (the form writes `SkillScenario` rows directly); add
  `showcase_artifact_version_id`; wire **▶ Run** → `SkillScenarioRun` (as `:skill_scenario`) capturing the
  showcase; render verdict + produced artifact.

## Non-goals (deferred)

- Preview panel, live conversation, AI-assisted authoring.
- Runtime injection of a skill's `preferred_skills`/`preferred_tools` as soft hints (author/display only).
- Per-version scenarios; auto-running scenarios (always user-triggered).
- Marketplace / publishing / favoriting.

## Invariants respected

- **Archive is the only source of a skill's content** — Save assembles `SKILL.md` → promotes a version;
  Load parses the selected version's archive. Never a card/soft-hint column.
- **DB is the source of truth** — the form writes `SkillVersion`s and `SkillScenario` rows directly.
- **Compose primitives** — the form + dialog are `component(...)`/`custom(...)`, never raw markup.
- **Self-validating runs are tagged** — `kind: :skill_scenario` + `auto: true`; the human is out of the
  loop by identity, and those sessions are filtered from the conversation list.

## Testing

- `SkillForm`: fields → `SKILL.md` (frontmatter round-trips every key incl. `preferred_*` lists + body);
  parse a version's archive back to fields; a stub-v1 skill parses the label as `name`.
- Controller: New dialog creates a stub skill (v1 present) → redirects to the form; `PATCH` promotes a
  new version whose parsed fields match the submitted form; `?version=` loads that version's fields.
- Session: `kind` defaults `:user`; the conversation index excludes `:skill_scenario`.
- Scenarios: the sub-form writes `SkillScenario` rows (steps jsonb); **▶ Run** produces a
  `:skill_scenario` session, self-validates, sets `showcase_artifact_version_id`.
- Dogfood: create a skill via the form, run a scenario with steps → assert the steps self-validated
  (completions recorded) and a showcase artifact was captured.
