# Custom Approvals — Implementation Plan

> Execute task-by-task, TDD, **on `main`** (no feature branch). Spec:
> `specs/2026-07-19-custom-approvals-design.md`.

**Goal:** `custom_approval!` — a gated tool declares its own card + own submission, resolved by
convention, boot-enforced; `ask_user` as the reference (structured question → picks → resume).

## Global constraints
- `client.ts` does NOT change — a custom gate parks via the existing `needs_approval`/`canUseTool` path.
- Tenancy always-on; the resume runs in a JOB; the nudge is the app's sentence, never a user message.
- No registry; boot enforcement is the guarantee (a half-built gate fails boot).

---

### T1 — Unstub `tools_validation_component`
**Files:** `app/helpers/rbrun/sessions_helper.rb`; test `test/helpers/rbrun/sessions_helper_test.rb`.
- Resolve `Rbrun::Sessions::ToolsValidation::#{name.camelize}::Component` via `safe_constantize`, fall
  back to `Default::Component`.
- Test: an existing per-tool card (define a throwaway `…::Widget::Component < Base` in the test) resolves
  for `"widget"`; an unknown name → `Default`.
- Commit.

### T2 — `custom_approval!(submit:)` on `ApplicationTool`
**Files:** `app/tools/rbrun/application_tool.rb`; test `test/tools/rbrun/application_tool_test.rb`.
- Add `self.custom_approval!(submit:)` (sets `@needs_approval`, `@custom_approval`,
  `@approval_submit_route`; `define_method(:execute) { |**| { "data" => { "gated" => submit.to_s } } }`),
  `custom_approval?`, `approval_submit_route`.
- Test: a tool with `custom_approval! submit: :x` → `needs_approval? == true`, `custom_approval? == true`,
  `approval_submit_route == :x`, and a bare `execute` returns the degrade hash; `manifest_entry` still
  reports `needs_approval: true`.
- Commit.

### T3 — `Rbrun::Conventions` + boot enforcement
**Files:** `app/services/rbrun/conventions.rb`, `app/tools/rbrun/application_tool.rb` (add
`validate_tool_approvals!`), `lib/rbrun/engine.rb` (call it in `after_initialize`); test
`test/tools/rbrun/tool_approvals_validation_test.rb`.
- `Rbrun::Conventions.resolve!(const, label, base: nil)` — folder-per-unit constant or raise
  `Conventions::Error`.
- `ApplicationTool.validate_tool_approvals!` — force routes loaded
  (`Rails.application.routes_reloader.execute_unless_loaded`); for each registered tool with
  `custom_approval?`, assert its `Rbrun::Sessions::ToolsValidation::<Name>::Component` (< Base) resolves
  AND its `approval_submit_route` is a named route — else raise.
- `engine.rb after_initialize`: `Rbrun::ApplicationTool.validate_tool_approvals!` after `config.validate!`.
- Test: a custom_approval tool missing its card raises; missing its route raises; a complete one passes.
- Commit.

### T4 — `ResolvesGate` concern + refactor `ApprovalsController`
**Files:** `app/controllers/concerns/rbrun/resolves_gate.rb`, `app/controllers/rbrun/approvals_controller.rb`;
extend `test/controllers/rbrun/sessions_flow_test.rb`.
- `Rbrun::ResolvesGate`: `pending_gate`, `claim_gate!(row, status:)`, `record_gate_result(row, result,
  is_error: false)`, `resume_turn(row, job, nudge)`, `render_gate_band(row)` (reuse
  `segment_locals_for` + the `sessions/segment` replace already in `ApprovalsController`).
- Refactor `ApprovalsController#update` onto the concern (its `decide_approval!` still runs the frozen
  Ruby call on approve; the yes/no path is unchanged in behaviour).
- Test: the existing approval flow (`sessions_flow_test` "deciding an approval …") stays green;
  double-submit is a no-op.
- Commit.

### T5 — `answered` status
**Files:** `app/models/rbrun/session_message.rb`; test `test/models/rbrun/session_message_test.rb` (or the
broadcast/model test).
- Add `answered` to the string-backed `approval_status` enum (no migration); `approval_answered?` follows
  from the enum.
- Test: a row set to `approval_status: "answered"` → `approval_answered?`; still counts as `gated`.
- Commit.

### T6 — `ask_user` (tool + card + controller + job + route)
**Files:** `app/tools/rbrun/tools/ask_user.rb`, `app/components/rbrun/sessions/tools_validation/ask_user/component.rb`
(+ `component.html.erb`), `app/controllers/rbrun/ask_user_responses_controller.rb`,
`app/jobs/rbrun/ask_user_turn_job.rb`, `config/routes.rb`; test
`test/controllers/rbrun/ask_user_flow_test.rb`.
- **Tool:** `custom_approval! submit: :ask_user_response`; `parameter :form_spec, type: "object",
  required: true`; no `execute`.
- **Card:** stepper (radio/checkbox from `form_spec`) while `pending`; the picked answers (off the call's
  `tool_result` `result.answers`) once `answered`. Posts to `ask_user_response_path(tool_use_id)`.
- **Controller** (`ResolvesGate`): `create` → `claim_gate!(row, status: "answered")` (no-op if lost) →
  `record_gate_result(row, { "answers" => permitted_answers })` → `AskUserTurnJob.perform_later(row.session_id,
  answers_nudge)` → `render_gate_band(row)`.
- **Job:** `perform(session_id, nudge) = Rbrun::Session.find(session_id).continue_turn!(nudge)`.
- **Route:** `post "ask_user/:tool_use_id", to: "ask_user_responses#create", as: :ask_user_response`.
- **Register** `Rbrun::Tools::AskUser` (dummy initializer for the test).
- Test: freeze a pending `ask_user` row with a `form_spec`; the segment renders the stepper (assert the
  options); POST picks → a `tool_result` with `result.answers` is written, the row is `answered`, and
  `AskUserTurnJob` is enqueued; the band re-renders showing the picks.
- Commit.

### T7 — Dogfood `dogfood/ask_user.rake`
**Files:** `lib/tasks/rbrun/dogfood/ask_user.rake`.
- One real turn (creds from `.env`): register `AskUser`; a prompt where the agent must ask a pick
  (e.g. "before answering, ask me to choose a color"); assert the run parks with a pending `ask_user`
  gate carrying a `form_spec` with options; submit picks via `AskUserResponsesController` path (or the
  model helpers); `continue_turn!` → the agent's reply reflects the chosen value. ✓/✗ + screenshots not
  needed. Gate on creds; never variabilized.
- Commit.

## Self-review
- Spec coverage: §1→T1, §2→T2, §3→T3, §4→T4, §5→T6, §6→T5, §8→T7. ✓
- Types: `custom_approval!`/`custom_approval?`/`approval_submit_route` (T2) consumed by
  `validate_tool_approvals!` (T3) and `ask_user` (T6); `ResolvesGate` methods (T4) consumed by both
  `ApprovalsController` and `AskUserResponsesController`. ✓
- No `client.ts` change; a custom gate reuses the `needs_approval` park. ✓
