# Custom Approvals — Design

> Feature spec. Extends the rbrun engine design (`2026-07-19-rbrun-design.md`) and the Phase-8
> conversation gate. Executed on `main` (no feature branch).

**Goal:** Generalize rbrun's gate from **`needs_approval` (yes/no)** to **`custom_approval!`** — a gated
tool can declare its **own inline card + own submission**, resolved by a folder-per-unit convention and
**boot-enforced**. Reference implementation: **`ask_user`** — the agent asks the user a *structured
question* (radio/checkbox), the picks become the call's result, the turn resumes.

## The gap this closes

`tools_validation_component(name)` is a **stub** — it throws the name away and always renders `Default`,
even though its own comment promises per-tool cards via `Rbrun::Sessions::ToolsValidation::<Name>::Component`.
And there is no way for a gated tool to have its **own submission**: every gate is the one yes/no
`ApprovalsController` running the frozen call in Ruby. So the agent can only ever *approve/deny a
dangerous tool* — it can't *ask the user a question*.

## 1. Rendering by convention (unstub the resolver)

```ruby
def tools_validation_component(name)
  const = "Rbrun::Sessions::ToolsValidation::#{name.to_s.camelize}::Component"
  const.safe_constantize || Rbrun::Sessions::ToolsValidation::Default::Component
end
```

A pending gate row renders **its tool's card** (`…::<Name>::Component`), falling back to `Default`. This
is the rendering half the codebase already documents but never wired.

## 2. `custom_approval!(submit:)` on `ApplicationTool`

A gated tool whose approval is a **custom inline card with its own submission** (a form), not the yes/no
controller. One declaration that is the gate AND the custom-card opt-in AND the submit route:

```ruby
def self.custom_approval!(submit:)
  @needs_approval = true          # a custom approval IS a gate
  @custom_approval = true
  @approval_submit_route = submit # the named route the card posts to
  # A gate tool has NO computed result — its "operation" is the user's submission (run by the submit
  # controller), so the declaration supplies the degrade execute a stray hand-call would need.
  define_method(:execute) { |**| { "data" => { "gated" => submit.to_s } } }
end
def self.custom_approval?      = @custom_approval == true
def self.approval_submit_route = @approval_submit_route
```

`manifest_entry` is unchanged (`needs_approval` stays true — the SDK parks it via `canUseTool` exactly
like any needs_approval tool). **`client.ts` does not change** — a custom gate parks identically; only
the Ruby-side *resolution* (which controller, how the result is produced) differs.

## 3. Boot enforcement — `Rbrun::Conventions`

The one boot-enforced convention backbone (rbrun has no artifacts, so it's just tool approvals):

```ruby
module Rbrun::Conventions
  Error = Class.new(StandardError)
  def self.resolve!(const, label, base: nil) # folder-per-unit constant or raise
end
```

`Rbrun::ApplicationTool.validate_tool_approvals!` (run in the engine's `after_initialize`, after
`config.validate!`) fails the boot if any `custom_approval!` tool lacks **its
`Rbrun::Sessions::ToolsValidation::<Name>::Component` card** *or* **its named submit route**. A next
contributor can't half-build a gate — the enforcement is the boot, not a skippable test.

## 4. `ResolvesGate` — the shared gate-resolution dance

Every gate-resolution endpoint does the same thing; factor it so a second (custom) submit controller
can't re-implement it slightly differently. `Rbrun::ResolvesGate` (a controller concern):

- **`pending_gate`** — the frozen pending `tool_use` row, tenant-scoped, by `params[:tool_use_id]`.
- **`claim_gate!(row, status:)`** — `UPDATE … WHERE approval_status = 'pending'` IS the lock (double
  submit updates nothing). Returns whether this request won it.
- **`record_gate_result(row, result, is_error:)`** — the call's own `tool_result` row (what the agent
  reads on resume).
- **`resume_turn(row, job, nudge)`** — resume off-request via a job; the nudge is the app's sentence.
- **`render_gate_band(row)`** — replace the segment/gate band in place (live == reload).

`ApprovalsController` (yes/no) is refactored onto it (its `decide_approval!` still runs the frozen Ruby
call on approve); `AskUserResponsesController` (§5) is the second consumer.

## 5. `ask_user` — the reference custom gate

- **`Rbrun::Tools::AskUser < ApplicationTool`** — `custom_approval! submit: :ask_user_response`;
  `parameter :form_spec, type: "object", required: true`; no `execute` (the degrade default suffices).
  Description: *ask the user to CHOOSE from options (radio/checkbox), never a free-text question.*
- **`form_spec`** shape: `{ title, steps: [ { title, questions: [ { key, label, input: "radio"|"checkbox",
  options: [ {value,label} ], required } ] } ] }`.
- **`Rbrun::Sessions::ToolsValidation::AskUser::Component`** — a radio/checkbox **stepper** while
  pending; the picked answers once answered (read off the call's `tool_result`).
- **`AskUserResponsesController#create`** (`ResolvesGate`): `claim_gate!(row, status: "answered")` →
  `record_gate_result(row, { "answers" => picks })` → `AskUserTurnJob.perform_later(session_id, nudge)`
  → `render_gate_band`. The nudge states the picks (the app's sentence, never a user message).
- Route: `post "ask_user/:tool_use_id", to: "ask_user_responses#create", as: :ask_user_response`.

## 6. Data — the `answered` status

`SessionMessage#approval_status` gains **`answered`** (string-backed enum → add the key, **no
migration**), for a custom gate that was submitted (distinct from `approved`/`rejected`). Predicate
`approval_answered?`. The segment's `approval` slot already reads `approval_status`.

## 7. Out of scope

`prepare_import`-style editable-table gates and any domain gate — the architecture supports them
(`custom_approval!` + a card + a route), but only `ask_user` ships as the proof.

## 8. Dogfood — `dogfood/ask_user.rake`

One real turn: the agent calls `ask_user` with a `form_spec` → the run parks with a pending `ask_user`
gate carrying the spec → submit picks (via the controller path) → `AskUserTurnJob` resumes → the agent
continues *knowing the picks*. Real Claude + sandbox. ✓/✗.

## 9. Inherited invariants

Tenancy always-on (gates tenant-scoped); the turn runs in a job, never inline; live == reload
(broadcast the same partial the turn renders); no registry — tools are host-registerable.
