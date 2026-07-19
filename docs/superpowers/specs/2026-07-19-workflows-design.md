# Workflows — Design

> Feature spec. Rides the approval machinery (`custom_approval!` + `ResolvesGate`, the custom-approvals
> work) and the skills subsystem. Executed on `main`. **The dogfood workflow is NOT built here** — the
> "agent self-validates" rider is out; the target is user-facing, gated skills orchestration.

## 0. What a workflow IS

A **workflow is UI guidance made durable: a task-progress band, docked to the composer, that the user
watches advance one *user-validated* step at a time.** Backed by a durable, reusable definition (label +
goal + ordered steps), it is *powerful* because it's a **library** of procedures — a workflow is to
*procedure* what a skill is to *capability*. The **workflow owns the conversation**, never the reverse:
`Workflow has_many :sessions` (its runs), never deleted; a `Session` is a disposable **run** of it.

Two layers, built in order:
1. **The run** (this build): one session executing its workflow — the band + the per-step gates.
2. **The library** (north star §9, *not built now*): browse/clone/edit durable workflows, start a new
   run from a saved one. The run layer keeps its seams open for it.

## 1. The run experience

The band, docked above the message form inside `#composer`, shows **the workflow this session runs** —
its ordered steps with this session's progress. The agent works one step at a time; **a step completes
only when the user validates it** — a pending dot flips to a green check, the counter ticks
`0/3 → 1/3 → …`, live. Validation is the *only* thing that moves the band.

## 2. Confirmed decisions

1. **Band on bind, gate per step.** Binding shows all steps pending at `0/N`; steps go green one gate
   at a time.
2. **One workflow per session.** `session.workflow` is the run; a new bind replaces the prior binding
   and **the prior workflow persists** (it still owns its other sessions).
3. **Cancel ≠ delete, keeps ownership.** Cancel sets `session.workflow_status: cancelled` (NOT clearing
   `workflow_id` — that would disown the session), hides the band; the workflow and the link stay.
4. **Collapse ≠ cancel.** The chevron collapses/expands the band (visual only, Stimulus + cookie).

## 3. Data model (rbrun DB, tenant-scoped)

Three tables + two columns on `rbrun_sessions`.

- **`Rbrun::Workflow`** — the durable definition. `include Rbrun::Tenanted` (tenant slug). Columns:
  `tenant`, `label` (not null), `goal` (text), `description` (text). `has_many :sessions, dependent:
  :nullify` (clearing a run never touches the workflow); `has_many :steps, -> { order(:position) },
  class_name: "Rbrun::WorkflowStep", dependent: :destroy`. `validates :label, presence`. **No run
  state** — the definition is shared.
- **`Rbrun::WorkflowStep`** — `workflow_id`, `position` (int), `title`. `belongs_to :workflow`. No
  per-run state.
- **`Rbrun::WorkflowStepCompletion`** — the per-session join. `session_id`, `workflow_step_id`,
  `user_message_id` (the `SessionMessage` turn lead the step was validated in), `completed_at`. Unique
  `[session_id, workflow_step_id]` (a step is done once per session). `belongs_to :session`,
  `:workflow_step`, `:user_message` (class `Rbrun::SessionMessage`).
- **`Session` gains** `workflow_id` (nullable FK) + `workflow_status` (string enum
  `{ active, completed, cancelled }`, prefix `:workflow_status`, nil when no run). `belongs_to
  :workflow, optional`; `has_many :workflow_step_completions, dependent: :destroy`;
  `Session#broadcast_workflow`.

### `Rbrun::Workflow::Run` — progress for ONE session (value object)

`Data.define(:session)` joining the shared steps to this session's completions (queries the join
directly, never a cached association):
`steps`, `done?(step)`, `current_step` (first with no completion), `done_count`, `total`, `all_done?`.

## 4. Tools (built-ins, registered in the engine after_initialize)

`ApplicationTool` subclasses, string-keyed results, `in_session(session)`, tenancy from the session.
English descriptions.

- **`workflow_create`** — **`custom_approval! submit: :workflow_decision`**. PROPOSES a plan (`label`,
  `goal?`, `description?`, `steps: [titles]`) and the run ENDS on a gate. The user decides via a
  3-button card — **Apply** (create + bind here), **Save** (create in the library only), **Cancel**
  (create nothing). No `execute` (the base degrade no-op). `WorkflowDecisionsController` (`ResolvesGate`)
  reads the FROZEN plan and does the work. Boot-enforced (A-T3): needs its card + `:workflow_decision`
  route.
- **`validate_step`** — plain **`needs_approval!`** (the action-on-approve family; `execute` runs on
  approve via `decide_approval! → run_frozen_call!`). No step-id param — always
  `Run.new(session).current_step`. `execute(summary: nil)`: create a completion for the current step
  (with `session.open_turn_lead&.id`), set `workflow_status_completed!` if `all_done?`, broadcast the
  band, return `{ done, total }`. Refuse → refusal nudge, nothing recorded. Its `ValidateStep` card is
  optional (falls back to `Default`); not boot-enforced.
- **`cancel_workflow`** — ungated. Sets `workflow_status_cancelled!` (keeps the binding), broadcasts.
- **`workflow_search`** — ungated read. A **portable** case-insensitive `LIKE` over `label`/`goal`/
  `description`, tenant-scoped (rbrun's DB may be sqlite or postgres — no `pg_search`; a host on
  postgres can swap in weighted full-text later).
- **`use_workflow`** — ungated reuse. Binds an existing workflow to the session as a fresh run (no
  re-validation); progress starts empty (completions are per-session).

## 5. UI — the run

- **Band partial** `app/views/rbrun/sessions/_workflow.html.erb` — inside `#composer`, above the message
  form, showing `Rbrun::Workflow::Run.new(session)`. Own broadcast target `#workflow_<session.id>`.
  Visible when `session.workflow && !session.workflow_status_cancelled?` (a completed run stays at
  `N/N`; cancelled shows none). Collapsed = one line (head step + check/dot + `done/total` + chevron);
  expanded = label/goal head + the ordered "Task progress" list + an **"Cancel workflow"** button.
- **Cancel button** = a canned message posted to the composer's OWN endpoint (`session_message_path`,
  `"Cancel the current workflow."`) — the agent reads it and calls `cancel_workflow`. No bespoke route.
- **Stimulus `workflow` controller** — collapse toggle + cookie `workflow_expanded` (the `sidebar`
  pattern); client-only.
- **`workflow_create` card** `…/tools_validation/workflow_create/` — pending: the plan + the 3 buttons
  posting a `decision` to `workflow_decision_path`; answered: a one-line recap off the tool_result.
- **`validate_step` card** `…/tools_validation/validate_step/` — the step + `summary`, an
  "Step complete — continue?" header, the shared `approval_actions`.
- **`Session#broadcast_workflow`** — `broadcast_replace_to "rbrun_session_#{id}", target:
  "workflow_#{id}", partial: "rbrun/sessions/workflow", locals: { session: self }`.

## 6. Cancellation & clearing

- `cancel_workflow` (agent tool) sets `workflow_status_cancelled!` (keeps `workflow_id`), broadcasts —
  band gone, workflow + ownership stay.
- **Clearing a session** cascades `dependent: :destroy` on its `workflow_step_completions`; via
  `Workflow has_many :sessions, dependent: :nullify` the workflow is untouched — "cleared, workflow
  persists" by construction.

## 7. Skill — `workflow-creator`

A pure-behaviour skill (SKILL.md), shipped as an engine built-in seeded via the skills subsystem: when
to declare a workflow (multi-step task with a clear goal — never a single step), work one step then
`validate_step` with a one-line summary, wait for the user to validate, revise on refuse, one workflow
per session (`workflow_create` re-binds), stop + confirm on cancel. Search+reuse before authoring.

## 8. Wiring summary (this build)

3 models + 1 value object + migration + 2 `Session` columns; 5 tools (built-ins); 1 band partial +
`broadcast_workflow` + inject into `#composer`; 2 cards; 1 Stimulus controller;
`WorkflowDecisionsController` (`ResolvesGate`) + `WorkflowDecisionTurnJob` + the `workflow_decision`
route; the `workflow-creator` skill. **No new gate mechanics** — rides `custom_approval!`/`ResolvesGate`
and `needs_approval!`/`ApprovalsController`.

## 9. Out of scope (this build)

The library menu / clone / edit / runs drawer; per-step thumbnails; editing steps after creation; the
**dogfood/e2e self-validation rider**. The run layer is built with seams open for the library (north
star), not built now.
