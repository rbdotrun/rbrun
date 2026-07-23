# Skill authoring & self-validating eval — design

**Date:** 2026-07-23
**Status:** design (one spec, two implementation plans)

## Purpose

Let the agent **author a skill from inside a conversation** and have it land, durably, in
rbrun's own skill store — then let a hand-authored **scenario** replay that skill and
self-validate, so a skill's correctness is provable the way a dogfood is.

This is deliberately **not** a port of Anthropic's `skill-creator` repo. That skill's eval
half (two subagents per test — with-skill vs baseline — driven by nested `claude -p`) needs a
second Claude runtime and a live token inside the sandbox, both of which rbrun keeps closed by
design. The prior art we port instead lives in the sibling `insitix` repo, whose skill model is
already the one rbrun uses (a folder ⇄ one gzipped-tar archive, versioned in the app DB) and
whose eval is a **single-turn self-validation** that fits rbrun's runtime with no new machinery.

The work splits into two plans that share one write-path contract, hence one spec:

- **Plan A — Authoring.** The agent writes a skill folder in its workspace; a `save_skill` tool
  packs it into the tarball archive and `promote!`s it into the DB, behind an inline approval gate.
- **Plan B — Scenario eval.** A new `SkillScenario` model + ingestion, and an orchestrator that
  seeds a workflow from the scenario's steps and replays it, the agent self-validating each step.

## What already exists (do not rebuild)

- `Rbrun::Skill` + `Rbrun::SkillVersion` — the skill store. `Skill#promote!(digest:, archive:,
  source:)` creates/points an immutable version; content-addressed, idempotent on digest.
- `Rbrun::SkillArchive` — folder ⇄ gzipped-tar blob + digest (`pack_files`, `files`, `unpack`,
  `digest`).
- `Rbrun::AgentTurn#materialize_skills` — stages the tenant's promoted skills into a temp dir the
  runtime mounts at `<workspace>/.claude/skills/`.
- `reload_skills` tool — stages DB → workspace (the inverse direction of `save_skill`).
- The **workflow spine**: `Rbrun::Workflow`, `Rbrun::WorkflowStep`, `Rbrun::WorkflowStepCompletion`,
  `Rbrun::Workflow::Run`, `Session#workflow`/`workflow_status`, and the `validate_step` tool
  (marks the current step complete, `needs_approval!`).
- Turns run as background jobs (`AgentTurnJob`), and a Session lives under a Worktree that owns the
  sandbox — so an eval run is an ordinary session, not a special substrate.

## Non-goals (deferred, additive later)

- **No git commit of the skill.** Authoring writes to the DB only. Committing the unpacked folder
  back to the repo (so `SkillSeeder` reconciles it) is a clean future addition and nothing here
  blocks it.
- **No with/baseline benchmark.** We answer "does the skill work correctly?" (scenario replay),
  not "does it beat baseline?" (A/B). The benchmark is a possible later refinement.
- **No in-engine authoring UI.** Authoring is agent-driven through the conversation; a dedicated
  in-engine "create skill" action is deferred.
- **No `SkillExample` (prompt → showcased result) model** in this spec. It is insitix's
  marketing/showcase concept, orthogonal to correctness; add later if a marketplace surface wants it.
- **Artifacts** (insitix's editable-React-app outputs) are a separate subsystem, not touched here.

---

## Plan A — Authoring

### Flow

1. A built-in `skill-creator` skill (ported/adapted from insitix's authoring guidance + Anthropic's
   writing guide, under the same permissive LICENSE) teaches the agent how to structure a skill:
   the `SKILL.md` frontmatter (name/description), progressive disclosure, `references/` layout, and
   the rbrun-specific fact that **a finished skill is saved with `save_skill`, not left as files**.
2. The agent authors the folder under `<workspace>/<slug>/` using its normal `Write`/`Edit` tools
   (already path-scoped to the workspace).
3. The agent calls `save_skill(slug:)`. The tool reads that folder, packs it with
   `SkillArchive.pack_files`, computes the digest, and promotes it for the current tenant.

### `save_skill` tool contract

```
save_skill(slug:) → { data: { slug:, name:, digest:, files: [rel paths], created: bool } }
```

- Reads `<workspace>/<slug>/` (must contain `SKILL.md`; error if absent or the folder is empty).
- `name` comes from the `SKILL.md` frontmatter `name:` (falls back to a titleized slug).
- Find-or-create the `Rbrun::Skill` row by `[tenant, slug]`, then `promote!(digest:, archive:,
  source: :agent)` — a **new `source` value** distinguishing agent-authored from `:file`/`:inline`.
- `created` reports whether the Skill row was new (first save of this slug) vs a re-save.

### Approval semantics — inline gate

`save_skill` is `needs_approval!`. The promotion is the human confirmation point: the tool packs
the artifact and the turn **parks**, surfacing the pending save (slug + name + whether it replaces
an existing skill) in the conversation via the existing approvals path. On approve, `promote!`
runs and the new version becomes `current_version`; on refuse, nothing is written. First creation
and re-save are both gated (simplest, and swapping a live skill is exactly a human decision) — the
`created` flag lets the approval UI phrase "create" vs "replace".

Because `promote!` is idempotent on digest and always makes a new immutable version, re-saving is
safe: history is never lost, "replace" means "a new version becomes current."

### Testing (A)

- Model/tool test: `save_skill` against a fixture workspace folder creates the Skill + version,
  digest matches `SkillArchive.digest`, `source: :agent`, re-save of identical bytes is a no-op
  promotion (same version), re-save of changed bytes makes a new current version.
- Approval test: the tool parks (`needs_approval`), approve promotes, refuse writes nothing.
- Dogfood (`lib/tasks/rbrun/dogfood/`): a real turn authors a trivial skill and saves it; assert a
  promoted version exists for the tenant. Reaps any prior fixture skill at start (idempotency #11).

---

## Plan B — Scenario self-validation

### Model — `Rbrun::SkillScenario`

Mirrors insitix's `MarketplaceSkillScenario`, adapted to rbrun naming.

Columns: `tenant` (Tenanted), `skill_id` (FK → `Rbrun::Skill`, **optional** — a nil skill is a
platform scenario), `label` (unique per `[tenant, skill]`), `description`, `prompt` (text, the
vague request to replay), `steps` (jsonb — ordered `[{label, description, gate?}]`), `attachments`
(jsonb — repo-relative fixture paths).

A step is `{label, description}` where `description` is *what to validate*. An optional
`gate: {tool, resolve}` marks a runner-driven step (`resolve ∈ approve|refuse|expect`).

### Ingestion

A `Rbrun::SkillScenarios` service (autoloaded, testable — not buried in a rake) reads a skill
folder's `scenarios/*.yml` and **upserts** each into a `SkillScenario` keyed `[skill, label]`
(idempotent, find-or-initialize). The `scenarios/` folder is **excluded from the staged archive**
(these seed the DB and drive eval; they never reach the agent's workspace) — `SkillArchive.pack_files`
gets a scenarios-excluding filter, or the packer already scopes to known skill files.

Driven from a rake task alongside the existing skill seeding.

### Orchestrator — `Rbrun::SkillScenarioRun`

Ports insitix's `Dogfood::Orchestrator` onto rbrun's spine. It asserts almost nothing itself: it
seeds a workflow from the scenario's steps, opens a turn with the scenario's **own prompt** (never
the plan — spoon-feeding the plan defeats the point), and reads back what the agent self-validated.

1. Create a Session under a fresh worktree/sandbox for the tenant, marked as a self-validating run
   (a `dogfood`/`autonomous` flag on the Session, or a `system_append` carrying the demo guidance —
   see below).
2. Seed a `Rbrun::Workflow` from the scenario steps (`WorkflowStep` per entry), bind it to the
   Session, set `workflow_status: active`.
3. Attach fixtures (`attachments`) to the opening turn exactly like a user dropping files.
4. `run_turn(scenario.prompt)`, then **`advance`**: while steps remain and the run is not frozen,
   drain any gate, then nudge the next turn with a neutral "continue" (never the plan). Bounded by
   `steps.size + GATE_GUARD` turns and a two-idle-turns stuck-detector.
5. `record`: per-step `{label, description, done, verdict, report, gate_ok}` + end summary + overall
   `pass` (all steps done AND every gate step validated *by the runner*, not self-approved).

**Self-validation without a human.** rbrun's `validate_step` is `needs_approval!` (a user
normally approves). In a scenario run there is no human, so the orchestrator **plays the approver**:
it auto-resolves the `validate_step` gate the same way it drives scenario gates. This reuses the
existing tool and gate path with **no new agent-facing tool** — the orchestrator is the only new
authority. (Alternative considered: a separate autonomous `self_validate_step` tool as in insitix.
Rejected for this spec — auto-approving the existing gate is less surface.)

**Demo guidance.** The orchestrator injects a short system append into every turn it drives (and
only those): "this is a self-validated run; your validation is worth only the proof behind it —
ground each step in the tool calls you actually made." Carried on the Session so all turns share it
(prompt-cache stable), never in the main agent prompt.

**Gate steps.** A `gate:` step is validated by the **runner**, not the agent: it confirms the gate
fired on the declared tool and resolves it (approve/refuse/expect). If such a step is instead marked
done by the agent, the gate never fired — a false pass — and `record` flags `gate_ok: false`.

### Surfacing

The run's result is DB-backed (a Session + its workflow + completions), so it surfaces through
existing conversation/workflow views. A minimal **eval result view** — per-step pass/fail + evidence
tool-call ids + overall verdict — is composed from `Rbrun::Ui::*` primitives (never hand-rolled
HTML, per CLAUDE.md). Trigger: a rake task first (`app:dogfood`-style), a Skills-panel button later.

### Testing (B)

- `SkillScenarios` ingestion: `scenarios/*.yml` → rows, idempotent upsert, `scenarios/` excluded
  from the packed archive.
- Orchestrator unit test with a stubbed turn: seeds the workflow, advances, records per-step
  verdicts, flags a self-approved gate step as `gate_ok: false`, respects the idle/stuck bound.
- Dogfood: a real scenario replays a real (previously saved) skill end-to-end and reports `pass`.
  Reaps prior run state at start, destroys its sandbox in `ensure` (idempotency #11).

---

## Invariants respected

- **DB is the source of truth for skills** — authoring writes the DB, never files/config (files
  only seed). `save_skill` is the DB write-path.
- **No second Claude runtime / no token in the box** — eval is a self-validating rbrun Session on
  the existing transport; no nested `claude`, no SDK client inside the sandbox.
- **No subagents** — the runtime strips Task/Agent tools; the orchestrator drives *sequential turns*
  of one session, not fan-out.
- **Idempotency (#11)** — ingestion upserts, `promote!` is find-or-create on digest, dogfoods reap
  at start and destroy at end.
- **Compose primitives (banner)** — any eval UI is `Rbrun::Ui::*`, never raw HTML.
- **Approval gate for sensitive mutation** — promoting a live skill parks for a human, like the
  exposure ladder's `share_public`.
```
