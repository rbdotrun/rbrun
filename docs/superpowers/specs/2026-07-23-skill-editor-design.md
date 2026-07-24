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

The only things not in the archive are DB rows in their own right: a skill's **`Workflow`s** (each a
runnable scenario/example — see below) and their **produced artifact** (`ArtifactVersion`). Those are
their own truth.

## Scenarios are skill-bound workflows (no wrapper model)

A "scenario"/"example" for a skill is **just a `Rbrun::Workflow` that belongs to that skill.** There is
no separate `SkillScenario` model — it collapses into `Workflow`. The `skill_id` is the whole
distinction: a workflow with `skill_id` **nil** is a plain conversation workflow (unchanged); a workflow
**bound to a skill** is that skill's runnable case.

```
Rbrun::Workflow
  label · goal · steps → WorkflowStep        (unchanged — conversations still create these)
  belongs_to :skill (optional)               SET ⇒ a runnable scenario/example for that skill
  prompt                                     the example prompt to replay (the vague request that
                                             should make the skill fire on its own)
  showcase_artifact_version_id → ArtifactVersion   the last run's produced artifact (a curated pointer)

Rbrun::Skill  has_many :workflows            a skill's workflows ARE its scenarios/examples
```

**Why merge (not a `SkillScenario` wrapping a `Workflow`):** the runtime is already built entirely on
`Workflow` — a session binds to a `Workflow` (`sessions.workflow_id`), `validate_step` records
completions against its `WorkflowStep`s, `Workflow::Run` computes progress. The scenario's expected steps
therefore have to *be* a `Workflow` for the run to bind and self-validate. Once they are, a separate
wrapper only re-holds `prompt`/`skill`/`showcase` — three columns that sit just as well on the workflow
they annotate. The cost is that `Workflow` gains three columns meaningful only when `skill_id` is present;
that mild nullable-subset is the accepted trade for one concept instead of two.

## What already exists (reuse)

- `Skill` + `SkillVersion` (immutable, digest-addressed, `current_version`, `promote!`).
- `SkillArchive` (`files`, `pack_files`, `digest_files`) + a line-by-line frontmatter reader pattern.
- `Rbrun::Workflow` + `Rbrun::WorkflowStep` (label/goal/steps, session binding, `Workflow::Run`
  progress) — reused directly as a skill's scenarios once `skill_id`/`prompt` are added.
- `SkillScenarioRun` (auto, self-validating) — binds a **skill-bound `Workflow`** to a
  `:skill_scenario` session, replays its `prompt`, self-validates each `WorkflowStep` (auto mode
  auto-approves `validate_step`).
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

### Scenarios (skill-bound workflows) — their own resource

A scenario is a skill-bound `Workflow`, so it gets **its own nested CRUD** rather than being saved as a
nested sub-form of the skill form (nested-in-nested jsonb editing is exactly the trap we're avoiding):

```
resources :skills, param: :slug do
  resources :workflows, only: %i[new create edit update destroy]   # a skill's scenarios
end
```

Each workflow form edits **one** `Workflow`: `label`, `prompt` (the example request to replay), `goal`,
and its **steps** — repeatable `{title, description}` rows saved as real `WorkflowStep` records via
`accepts_nested_attributes_for :steps` (add/remove is standard Rails, no jsonb, no hidden-field JSON).
Steps are the workflow the skill should produce; no steps = a pure showcase.

- **▶ Run** enqueues `SkillScenarioRun` (auto, self-validating). It binds **this** workflow to a
  `kind: :skill_scenario` session, replays `workflow.prompt`, self-validates each `WorkflowStep`, and
  captures the produced artifact into `workflow.showcase_artifact_version_id`. Completions are
  per-session, so re-runs never collide; the session is reaped after, the workflow persists.
- After a run: show the verdict (steps done/total) + the produced artifact (versioned — re-run adds a
  version). Runs are user-triggered, one at a time.

## Model additions

- **`rbrun_sessions.kind`** — enum `{ user: "user", skill_scenario: "skill_scenario" }`, default
  `"user"`, not null. `SkillScenarioRun` sessions are `:skill_scenario` (ephemeral, machine-driven,
  self-validating); everything else is `:user`. The **conversation index filters to `:user`** so
  scenario runs don't pollute it. (`kind` is the durable "what is this session"; `auto` stays the
  runtime lever.) Enum kept open for future kinds.
- **`rbrun_workflows.skill_id`** — FK → `rbrun_skills` (nullable): set ⇒ this workflow is that skill's
  scenario/example. `Skill has_many :workflows`, `Workflow belongs_to :skill, optional: true`. A nil
  `skill_id` is a plain conversation workflow (unchanged).
- **`rbrun_workflows.prompt`** — text (nullable): the example prompt `SkillScenarioRun` replays for a
  skill-bound workflow.
- **`rbrun_workflows.showcase_artifact_version_id`** — FK → `rbrun_artifact_versions` (nullable): the
  artifact the workflow's last run produced. A curated *pointer* (not archive content). Set by
  `SkillScenarioRun`; artifacts already survive the run's reaping (the completion→message FK nullifies).
- **Retire `SkillScenario`** — drop the model, table, and `SkillScenarios.ingest`'s jsonb path; scenario
  data now lives on `Workflow`. `scenarios/*.yml` seeding becomes "find-or-create a skill-bound
  `Workflow` + its `WorkflowStep`s" (idempotent, per invariant 11).

No `SkillScenario`, no `SkillExample`, no `editing_skill_id`, no card/soft-hint columns.

## Plans (one spec, two plans, build in order)

- **Plan 1 — the skill form + versions.** `Rbrun::SkillForm` (fields ⇄ `SKILL.md`: name/label/tagline/
  icon/kind/example/description/body + `preferred_skills`/`preferred_tools`); vanilla `new`/`create`/
  `edit`/`update` (create → v1, update → `promote!` a new version); the version dropdown (load a version's
  archive into the form). `rbrun_sessions.kind` enum + index filter. Delivers full skill editing.
- **Plan 2 — scenarios = skill-bound workflows + run.** Add `workflows.skill_id` / `prompt` /
  `showcase_artifact_version_id` (+ `Skill has_many :workflows`, `Workflow belongs_to :skill`); retire
  `SkillScenario` (drop model/table, re-point `SkillScenarioRun` to bind a skill-bound `Workflow` and
  replay its `prompt`, migrate `SkillScenarios.ingest` to find-or-create workflows). Nested
  `resources :workflows` under `:skills` with a `Workflow` form (label/prompt/goal + `WorkflowStep`s via
  `accepts_nested_attributes_for`); wire **▶ Run** → `SkillScenarioRun` (as `:skill_scenario`) capturing
  the showcase; render verdict + produced artifact.

## Non-goals (deferred)

- Preview panel, live conversation, AI-assisted authoring.
- Runtime injection of a skill's `preferred_skills`/`preferred_tools` as soft hints (author/display only).
- Per-version scenarios; auto-running scenarios (always user-triggered).
- Marketplace / publishing / favoriting.

## Invariants respected

- **Archive is the only source of a skill's content** — Save assembles `SKILL.md` → promotes a version;
  Load parses the selected version's archive. Never a card/soft-hint column.
- **DB is the source of truth** — the form writes `SkillVersion`s and skill-bound `Workflow`s (+ their
  `WorkflowStep`s) directly.
- **Compose primitives** — the form is built from `field`/`input`/`textarea`/`select`/`multi_select`/
  `button` via `component(...)`, never raw `<input>`/`<form>` controls.
- **Self-validating runs are tagged** — `kind: :skill_scenario` + `auto: true`; the human is out of the
  loop by identity, and those sessions are filtered from the conversation list.

## Testing

- `SkillForm`: fields → `SKILL.md` (frontmatter round-trips every key incl. `preferred_*` lists + body);
  parse a version's archive back to fields (assemble/parse are inverses).
- Controller: `POST skills` creates a skill with a v1 assembled from the form; `PATCH skills/:slug`
  promotes a new version whose parsed fields match the submitted form; `?version=` loads that version's
  fields into the edit form.
- Session: `kind` defaults `:user`; the conversation index excludes `:skill_scenario`.
- Scenarios: the nested `workflows` form creates a **skill-bound `Workflow`** with `WorkflowStep`s
  (nested attributes, no jsonb); `Skill#workflows` returns it; **▶ Run** produces a `:skill_scenario`
  session, self-validates each step, sets `workflow.showcase_artifact_version_id`.
- Retirement: `SkillScenario` model/table are gone; `SkillScenarios.ingest` find-or-creates skill-bound
  workflows from `scenarios/*.yml` idempotently (re-ingest adds no duplicates).
- Dogfood: create a skill via the form, run a scenario (skill-bound workflow) with steps → assert the
  steps self-validated (completions recorded) and a showcase artifact was captured.
