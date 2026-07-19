# Workflows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A durable, reusable **task-progress band** docked above the composer that the user watches
advance one **user-validated** step at a time — riding rbrun's existing `custom_approval!` / `ResolvesGate`
/ `needs_approval!` / skills rails.

**Architecture:** Three tables (`Rbrun::Workflow` + `WorkflowStep` + per-session `WorkflowStepCompletion`)
+ two `Session` columns (`workflow_id`, `workflow_status`). A frozen `Workflow::Run` value object joins the
shared steps to one session's completions. Five built-in tools drive it: `workflow_create` (a
`custom_approval!` gate → `WorkflowDecisionsController`), `validate_step` (a `needs_approval!` gate whose
`execute` records a completion), and ungated `cancel_workflow` / `workflow_search` / `use_workflow`. The
band is a Turbo-broadcast sibling **above** `#composer` (not inside — `broadcast_composer` replaces
`#composer` wholesale on every status flip, which would wipe an embedded band).

**Tech Stack:** Rails 8.1 engine, ViewComponent (folder-per-unit cards), Turbo Streams, Stimulus, sqlite/pg
(portable `LIKE` search), RubyLLM tool base.

## Global Constraints

- Ruby 3.4.4, Rails `>= 8.1.3`. Engine: `bin/rails` runs against `test/dummy`; namespaced tables
  `rbrun_*`; tenancy column name is `Rbrun.config.tenancy_key` (string `"tenant"`), NOT NULL, default slug
  `"rbrun"`. Tenant scope is single-arg `for_tenant(slug)`.
- **No registry**; tools are registered in `lib/rbrun/engine.rb` `after_initialize` via
  `Rbrun.register_tool`. A `custom_approval!` tool is **boot-enforced**: its
  `Rbrun::Sessions::ToolsValidation::<Name>::Component` card AND its named submit route must exist, or the
  engine fails to boot. **Therefore `register_tool(Rbrun::Tools::WorkflowCreate)` lands in the SAME task
  that creates its card + route (Task 6) — never before.**
- English copy only (the repo reads as ours). No French. No `pg_search`.
- Tool results are string-keyed: `{ "data" => … }` on success, `{ "error" => "…" }` on a recoverable
  failure (`error(msg)` helper). `execute` returns, never raises for recoverable errors.
- Work on `main` directly. Run `bin/rails test` after each task. **No dogfood scenario is built.**

## File Structure

- `db/migrate/20260719160000_create_rbrun_workflows.rb` — 3 tables + 2 session columns (one migration).
- `app/models/rbrun/workflow.rb` · `workflow/run.rb` · `workflow_step.rb` · `workflow_step_completion.rb`
- `app/models/rbrun/session.rb` — MODIFY: workflow association, enum, `broadcast_workflow`.
- `app/tools/rbrun/tools/{workflow_create,validate_step,cancel_workflow,workflow_search,use_workflow}.rb`
- `app/controllers/rbrun/workflow_decisions_controller.rb` · `app/jobs/rbrun/workflow_decision_turn_job.rb`
- `app/components/rbrun/sessions/tools_validation/{workflow_create,validate_step}/component.{rb,html.erb}`
- `app/views/rbrun/sessions/_workflow.html.erb` — the band.
- `app/components/rbrun/sessions/base/component.html.erb` — MODIFY: render the band above `#composer`.
- `app/javascript/rbrun/controllers/workflow_controller.js` + `rbrun.js` — MODIFY: register + rebuild.
- `config/routes.rb` — MODIFY: the `workflow_decision` route.
- `lib/rbrun/engine.rb` — MODIFY: register the 5 tools; seed the built-in skill.
- `app/skills/workflow-creator/SKILL.md` + `app/services/rbrun/skill_seeder.rb` — MODIFY: seed engine
  built-in skills.
- Tests under `test/models/rbrun/`, `test/tools/rbrun/`, `test/controllers/rbrun/`.

---

### Task 1: Migration + Workflow + WorkflowStep models

**Files:**
- Create: `db/migrate/20260719160000_create_rbrun_workflows.rb`
- Create: `app/models/rbrun/workflow.rb`, `app/models/rbrun/workflow_step.rb`
- Test: `test/models/rbrun/workflow_test.rb`

**Interfaces:**
- Produces: `Rbrun::Workflow` (`Tenanted`; `has_many :sessions` nullify, `:steps` ordered destroy;
  `validates :label`; `scope :search`), `Rbrun::WorkflowStep` (`belongs_to :workflow`,
  `has_many :completions`, `validates :title`). Tables `rbrun_workflows`, `rbrun_workflow_steps`,
  `rbrun_workflow_step_completions`, and `rbrun_sessions.workflow_id` + `.workflow_status`.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260719160000_create_rbrun_workflows.rb
class CreateRbrunWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_workflows do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :label, null: false
      t.text   :goal
      t.text   :description
      t.timestamps
    end
    add_index :rbrun_workflows, Rbrun.config.tenancy_key

    create_table :rbrun_workflow_steps do |t|
      t.references :workflow, null: false, foreign_key: { to_table: :rbrun_workflows }
      t.integer :position, null: false
      t.string  :title,    null: false
      t.timestamps
    end

    create_table :rbrun_workflow_step_completions do |t|
      t.references :session,       null: false, foreign_key: { to_table: :rbrun_sessions }
      t.references :workflow_step, null: false, foreign_key: { to_table: :rbrun_workflow_steps }
      t.references :user_message,  foreign_key: { to_table: :rbrun_session_messages }
      t.datetime :completed_at
      t.timestamps
    end
    add_index :rbrun_workflow_step_completions, [ :session_id, :workflow_step_id ],
              unique: true, name: "idx_rbrun_wsc_session_step"

    add_reference :rbrun_sessions, :workflow, foreign_key: { to_table: :rbrun_workflows }
    add_column :rbrun_sessions, :workflow_status, :string
  end
end
```

- [ ] **Step 2: Write `Rbrun::Workflow`**

```ruby
# app/models/rbrun/workflow.rb
module Rbrun
  # A durable, reusable task procedure — label + goal + ordered steps. It OWNS its runs
  # (has_many :sessions); a Session is a disposable run of it. Never deleted by clearing a run.
  class Workflow < ApplicationRecord
    include Rbrun::Tenanted

    has_many :sessions, class_name: "Rbrun::Session", dependent: :nullify
    has_many :steps, -> { order(:position) }, class_name: "Rbrun::WorkflowStep", dependent: :destroy

    validates :label, presence: true

    # Portable, tenant-agnostic keyword search (sqlite + pg): case-insensitive LIKE across the text
    # columns. A pg host can later swap in weighted full-text without touching callers.
    scope :search, ->(query) {
      term = query.to_s.strip
      next none if term.empty?

      like = "%#{sanitize_sql_like(term).downcase}%"
      where("LOWER(label) LIKE :q OR LOWER(COALESCE(goal, '')) LIKE :q OR LOWER(COALESCE(description, '')) LIKE :q", q: like)
    }
  end
end
```

- [ ] **Step 3: Write `Rbrun::WorkflowStep`**

```ruby
# app/models/rbrun/workflow_step.rb
module Rbrun
  # One ordered step of a Workflow definition. Carries no per-run state — progress lives in
  # WorkflowStepCompletion, keyed by session.
  class WorkflowStep < ApplicationRecord
    belongs_to :workflow, class_name: "Rbrun::Workflow"
    has_many :completions, class_name: "Rbrun::WorkflowStepCompletion", dependent: :destroy

    validates :title, presence: true
  end
end
```

- [ ] **Step 4: Write the failing test**

```ruby
# test/models/rbrun/workflow_test.rb
require "test_helper"

module Rbrun
  class WorkflowTest < ActiveSupport::TestCase
    def build_workflow(label:, goal: nil, steps: [], tenant: "rbrun")
      wf = Rbrun::Workflow.new(label: label, goal: goal)
      wf[Rbrun.config.tenancy_key] = tenant
      wf.save!
      steps.each_with_index { |title, i| wf.steps.create!(position: i, title: title) }
      wf
    end

    test "requires a label" do
      wf = Rbrun::Workflow.new
      wf[Rbrun.config.tenancy_key] = "rbrun"
      refute wf.valid?
      assert_includes wf.errors[:label], "can't be blank"
    end

    test "steps come back ordered" do
      wf = build_workflow(label: "Ship", steps: %w[a b c])
      assert_equal %w[a b c], wf.steps.map(&:title)
    end

    test "search matches label, goal, description case-insensitively; blank returns none" do
      hit = build_workflow(label: "Release Pipeline", goal: "Cut a version")
      build_workflow(label: "Unrelated")
      assert_includes Rbrun::Workflow.search("release"), hit
      assert_includes Rbrun::Workflow.search("VERSION"), hit
      assert_empty Rbrun::Workflow.search("   ")
    end

    test "search is tenant-scopable via for_tenant" do
      mine = build_workflow(label: "Mine", tenant: "rbrun")
      build_workflow(label: "Mine too", tenant: "other")
      assert_equal [ mine ], Rbrun::Workflow.for_tenant("rbrun").search("mine").to_a
    end
  end
end
```

- [ ] **Step 5: Migrate the test DB and run the test**

Run: `bin/rails db:test:prepare && bin/rails test test/models/rbrun/workflow_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add db/migrate app/models/rbrun/workflow.rb app/models/rbrun/workflow_step.rb test/models/rbrun/workflow_test.rb db/schema.rb
git commit -m "feat(workflows): Workflow + WorkflowStep models and migration"
```

---

### Task 2: WorkflowStepCompletion + Session wiring

**Files:**
- Create: `app/models/rbrun/workflow_step_completion.rb`
- Modify: `app/models/rbrun/session.rb`
- Test: `test/models/rbrun/session_workflow_test.rb`

**Interfaces:**
- Consumes: `Rbrun::Workflow`, `Rbrun::WorkflowStep` (Task 1); `Session#open_turn_lead`.
- Produces: `Rbrun::WorkflowStepCompletion` (`belongs_to :session/:workflow_step/:user_message`).
  `Session#workflow` (optional), `Session#workflow_step_completions`, enum `workflow_status`
  (`active/completed/cancelled`, prefix `:workflow_status`), `Session#broadcast_workflow`.

- [ ] **Step 1: Write `Rbrun::WorkflowStepCompletion`**

```ruby
# app/models/rbrun/workflow_step_completion.rb
module Rbrun
  # A step marked done in ONE session's run, in a specific turn (user_message = the turn lead). Progress
  # is per-session: the same step is completed independently in each run. Unique per [session, step].
  class WorkflowStepCompletion < ApplicationRecord
    belongs_to :session, class_name: "Rbrun::Session"
    belongs_to :workflow_step, class_name: "Rbrun::WorkflowStep"
    belongs_to :user_message, class_name: "Rbrun::SessionMessage", optional: true
  end
end
```

- [ ] **Step 2: Modify `Session` — associations, enum, broadcast**

In `app/models/rbrun/session.rb`, after the `has_many :commits` line (line ~12) add:

```ruby
    belongs_to :workflow, class_name: "Rbrun::Workflow", optional: true
    has_many :workflow_step_completions, class_name: "Rbrun::WorkflowStepCompletion", dependent: :destroy
```

After the `enum :status,` block (line ~16) add:

```ruby
    enum :workflow_status,
         { active: "active", completed: "completed", cancelled: "cancelled" },
         prefix: :workflow_status, validate: { allow_nil: true }
```

In the `# ── the timeline` region (after `open_turn_lead`, ~line 66) add:

```ruby
    # Repaint just the task-progress band (its own target, independent of the composer swap).
    def broadcast_workflow
      ::Turbo::StreamsChannel.broadcast_replace_to("rbrun_session_#{id}",
        target: "workflow_#{id}", partial: "rbrun/sessions/workflow", locals: { session: self })
    end
```

- [ ] **Step 3: Write the failing test**

```ruby
# test/models/rbrun/session_workflow_test.rb
require "test_helper"

module Rbrun
  class SessionWorkflowTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      @workflow = Rbrun::Workflow.new(label: "Ship")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @step = @workflow.steps.create!(position: 0, title: "Bump")
    end

    test "a session binds a workflow and carries a nil-able prefixed status" do
      assert_nil @session.workflow_status
      @session.update!(workflow: @workflow, workflow_status: "active")
      assert @session.workflow_status_active?
      @session.workflow_status_cancelled!
      assert @session.workflow_status_cancelled?
    end

    test "completions are per-session and cascade on session destroy" do
      c = @session.workflow_step_completions.create!(workflow_step: @step, completed_at: Time.current)
      assert_equal [ c ], @session.workflow_step_completions.to_a
      assert_difference("Rbrun::WorkflowStepCompletion.count", -1) { @session.destroy }
    end

    test "clearing a session nullifies the link but keeps the workflow" do
      @session.update!(workflow: @workflow)
      @session.destroy
      assert Rbrun::Workflow.exists?(@workflow.id), "workflow persists after its run is cleared"
    end
  end
end
```

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/models/rbrun/session_workflow_test.rb`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/models/rbrun/workflow_step_completion.rb app/models/rbrun/session.rb test/models/rbrun/session_workflow_test.rb
git commit -m "feat(workflows): per-session completions + Session workflow binding"
```

---

### Task 3: `Rbrun::Workflow::Run` value object

**Files:**
- Create: `app/models/rbrun/workflow/run.rb`
- Test: `test/models/rbrun/workflow_run_test.rb`

**Interfaces:**
- Consumes: Task 1 + 2 models.
- Produces: `Rbrun::Workflow::Run.new(session)` — `steps`, `done?(step)`, `current_step`, `done_count`,
  `total`, `all_done?`. Frozen `Data`, no memoization (each call re-queries the join → live == reload).

- [ ] **Step 1: Write `Run`**

```ruby
# app/models/rbrun/workflow/run.rb
module Rbrun
  class Workflow
    # Progress of ONE session against its bound workflow. A frozen value object: it re-reads the
    # completion join on each call (never a cached association), so a fresh Run.new(session) after an
    # insert reflects it immediately.
    Run = Data.define(:session) do
      def workflow = session.workflow
      def steps = workflow ? workflow.steps.to_a : []

      def completed_step_ids
        Rbrun::WorkflowStepCompletion.where(session_id: session.id).pluck(:workflow_step_id).to_set
      end

      def done?(step) = completed_step_ids.include?(step.id)
      def current_step = steps.find { |step| !done?(step) }
      def done_count = steps.count { |step| completed_step_ids.include?(step.id) }
      def total = steps.size
      def all_done? = total.positive? && done_count == total
    end
  end
end
```

- [ ] **Step 2: Write the failing test**

```ruby
# test/models/rbrun/workflow_run_test.rb
require "test_helper"

module Rbrun
  class WorkflowRunTest < ActiveSupport::TestCase
    setup do
      @session  = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b").sessions.create!
      @workflow = Rbrun::Workflow.new(label: "Ship")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @s1 = @workflow.steps.create!(position: 0, title: "one")
      @s2 = @workflow.steps.create!(position: 1, title: "two")
      @session.update!(workflow: @workflow, workflow_status: "active")
    end

    def run = Rbrun::Workflow::Run.new(@session)

    test "empty run: current is the first step, nothing done" do
      assert_equal @s1, run.current_step
      assert_equal 0, run.done_count
      assert_equal 2, run.total
      refute run.all_done?
    end

    test "completing the current step advances current and the count, live" do
      @session.workflow_step_completions.create!(workflow_step: @s1, completed_at: Time.current)
      assert_equal @s2, run.current_step
      assert_equal 1, run.done_count
      refute run.all_done?
    end

    test "all steps done → all_done?, current is nil" do
      @workflow.steps.each { |s| @session.workflow_step_completions.create!(workflow_step: s, completed_at: Time.current) }
      assert run.all_done?
      assert_nil run.current_step
    end

    test "no workflow bound → empty, not all_done" do
      @session.update!(workflow: nil)
      assert_equal 0, run.total
      refute run.all_done?
    end
  end
end
```

- [ ] **Step 3: Run the test**

Run: `bin/rails test test/models/rbrun/workflow_run_test.rb`
Expected: PASS (4 tests).

- [ ] **Step 4: Commit**

```bash
git add app/models/rbrun/workflow/run.rb test/models/rbrun/workflow_run_test.rb
git commit -m "feat(workflows): Workflow::Run per-session progress value object"
```

---

### Task 4: The five tools

**Files:**
- Create: `app/tools/rbrun/tools/{workflow_create,validate_step,cancel_workflow,workflow_search,use_workflow}.rb`
- Test: `test/tools/rbrun/workflow_tools_test.rb`

**Interfaces:**
- Consumes: `Workflow`, `WorkflowStep`, `Workflow::Run`, `Session#workflow_step_completions`,
  `Session#open_turn_lead`, `Session#broadcast_workflow`, `Session#workflow_status_*!`,
  `ApplicationTool#tenant/#session/#error`, `custom_approval!`, `needs_approval!`.
- Produces: `Rbrun::Tools::{WorkflowCreate,ValidateStep,CancelWorkflow,WorkflowSearch,UseWorkflow}`.
  NOTE: NOT registered here (registration is Task 6, when the card + route exist). Tools are tested by
  instantiating `.in_session(session)` directly.

- [ ] **Step 1: `workflow_create` (custom_approval! — no execute)**

```ruby
# app/tools/rbrun/tools/workflow_create.rb
module Rbrun
  module Tools
    # Propose a durable, multi-step workflow. A custom gate: the run ENDS on the proposal and the user
    # decides via a 3-button card (Apply / Save / Cancel) handled by WorkflowDecisionsController. No
    # execute — a gate tool's operation IS the user's submission (custom_approval! supplies the degrade).
    class WorkflowCreate < Rbrun::ApplicationTool
      custom_approval! submit: :workflow_decision

      description <<~TXT
        Propose a multi-step workflow (a durable, reusable task procedure) for the user to review. Use it
        for any task with a clear goal and MORE THAN ONE step — never for a single step. The run ENDS on
        this proposal; the user decides via a card: Apply (create it AND start it here), Save (add to the
        library only), or Cancel (create nothing). `steps` are short imperative titles, in order.
        Example: { "label": "Ship the release", "goal": "Cut and publish v2.0",
                   "steps": ["Bump the version", "Update the changelog", "Tag and push"] }
      TXT

      parameter :label, type: "string", description: "a short name for the workflow", required: true
      parameter :goal, type: "string", description: "the outcome the workflow achieves"
      parameter :description, type: "string", description: "optional longer context"
      parameter :steps, type: "array", items: -> { { "type" => "string" } },
                description: "ordered list of short step titles", required: true
    end
  end
end
```

- [ ] **Step 2: `validate_step` (needs_approval! — execute records the completion)**

```ruby
# app/tools/rbrun/tools/validate_step.rb
module Rbrun
  module Tools
    # Mark the CURRENT workflow step complete — pending the user's approval. On approve the frozen
    # execute runs (records a per-session completion, advances the band, completes the run on the last
    # step). A plain needs_approval! gate: the yes/no ApprovalsController resolves it.
    class ValidateStep < Rbrun::ApplicationTool
      needs_approval!

      description <<~TXT
        Mark the CURRENT workflow step complete — pending the user's approval. Call this ONLY after you
        have actually finished the current step. On approval the task-progress band advances to the next
        step; on refusal nothing is recorded and you should address the user's feedback. `summary` is one
        short line describing what you completed.
      TXT

      parameter :summary, type: "string", description: "one line: what you completed for this step"

      def execute(summary: nil)
        step = Rbrun::Workflow::Run.new(session).current_step
        return error("no active workflow step to validate") unless step

        session.workflow_step_completions.create!(
          workflow_step: step, user_message: session.open_turn_lead, completed_at: Time.current
        )
        run = Rbrun::Workflow::Run.new(session) # fresh read after the insert
        session.workflow_status_completed! if run.all_done?
        session.broadcast_workflow

        { "data" => { "step" => step.title, "summary" => summary, "done" => run.done_count,
                      "total" => run.total, "all_done" => run.all_done? } }
      end
    end
  end
end
```

- [ ] **Step 3: `cancel_workflow`, `workflow_search`, `use_workflow` (ungated)**

```ruby
# app/tools/rbrun/tools/cancel_workflow.rb
module Rbrun
  module Tools
    # Stop the workflow running in this conversation. Keeps the binding + the workflow (cancel ≠ delete):
    # it only sets the run's status to cancelled and hides the band.
    class CancelWorkflow < Rbrun::ApplicationTool
      description "Cancel the workflow currently running in this conversation. The workflow itself is kept; only this run stops and its progress band is hidden."

      def execute
        return error("no workflow is running") unless session.workflow_id && !session.workflow_status_cancelled?

        session.workflow_status_cancelled!
        session.broadcast_workflow
        { "data" => { "cancelled" => true } }
      end
    end
  end
end
```

```ruby
# app/tools/rbrun/tools/workflow_search.rb
module Rbrun
  module Tools
    # Find reusable workflows in the library before authoring a new one.
    class WorkflowSearch < Rbrun::ApplicationTool
      description "Search the workflow library by keyword (matches label, goal, and description). Use this BEFORE proposing a new workflow, to reuse an existing one."

      parameter :query, type: "string", description: "keywords to match", required: true

      def execute(query:)
        workflows = Rbrun::Workflow.for_tenant(tenant).search(query).limit(10).map do |wf|
          { "id" => wf.id, "label" => wf.label, "goal" => wf.goal, "steps" => wf.steps.map(&:title) }
        end
        { "data" => { "workflows" => workflows } }
      end
    end
  end
end
```

```ruby
# app/tools/rbrun/tools/use_workflow.rb
module Rbrun
  module Tools
    # Start a fresh run of an existing workflow (from workflow_search) in this conversation. Progress
    # starts empty — completions are per-session, so a reused workflow re-validates from step one.
    class UseWorkflow < Rbrun::ApplicationTool
      description "Start a run of an existing workflow (by id, from workflow_search) in this conversation. Binds it and shows its progress band at step one."

      parameter :workflow_id, type: "integer", description: "the id of a workflow from workflow_search", required: true

      def execute(workflow_id:)
        workflow = Rbrun::Workflow.for_tenant(tenant).find_by(id: workflow_id)
        return error("no such workflow: #{workflow_id}") unless workflow

        session.update!(workflow: workflow, workflow_status: "active")
        session.broadcast_workflow
        { "data" => { "label" => workflow.label, "total" => Rbrun::Workflow::Run.new(session).total } }
      end
    end
  end
end
```

- [ ] **Step 4: Write the failing test**

```ruby
# test/tools/rbrun/workflow_tools_test.rb
require "test_helper"

module Rbrun
  class WorkflowToolsTest < ActiveSupport::TestCase
    setup do
      @session  = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b").sessions.create!
      @workflow = Rbrun::Workflow.new(label: "Ship", goal: "cut a release")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @s1 = @workflow.steps.create!(position: 0, title: "one")
      @s2 = @workflow.steps.create!(position: 1, title: "two")
    end

    def tool(klass) = klass.in_session(@session)

    test "workflow_create is a custom_approval gate with no real execute" do
      assert Rbrun::Tools::WorkflowCreate.custom_approval?
      assert Rbrun::Tools::WorkflowCreate.needs_approval?
      assert_equal :workflow_decision, Rbrun::Tools::WorkflowCreate.approval_submit_route
    end

    test "validate_step records the current step, advances, completes on the last" do
      @session.update!(workflow: @workflow, workflow_status: "active")
      r1 = tool(Rbrun::Tools::ValidateStep).execute(summary: "did one")
      assert_equal "one", r1.dig("data", "step")
      assert_equal 1, r1.dig("data", "done")
      refute r1.dig("data", "all_done")
      assert_equal @s2, Rbrun::Workflow::Run.new(@session).current_step

      r2 = tool(Rbrun::Tools::ValidateStep).execute(summary: "did two")
      assert r2.dig("data", "all_done")
      assert @session.reload.workflow_status_completed?
    end

    test "validate_step errors when there is no current step" do
      assert_includes tool(Rbrun::Tools::ValidateStep).execute["error"], "no active workflow step"
    end

    test "cancel_workflow keeps the binding, sets cancelled" do
      @session.update!(workflow: @workflow, workflow_status: "active")
      assert tool(Rbrun::Tools::CancelWorkflow).execute.dig("data", "cancelled")
      assert @session.reload.workflow_status_cancelled?
      assert_equal @workflow.id, @session.workflow_id, "binding kept"
    end

    test "workflow_search is tenant-scoped and keyword-matched" do
      hits = tool(Rbrun::Tools::WorkflowSearch).execute(query: "release").dig("data", "workflows")
      assert_equal [ "Ship" ], hits.map { |h| h["label"] }
      assert_empty tool(Rbrun::Tools::WorkflowSearch).execute(query: "nomatch").dig("data", "workflows")
    end

    test "use_workflow binds a fresh run (progress empty)" do
      res = tool(Rbrun::Tools::UseWorkflow).execute(workflow_id: @workflow.id)
      assert_equal "Ship", res.dig("data", "label")
      assert_equal 2, res.dig("data", "total")
      assert @session.reload.workflow_status_active?
      assert_equal 0, Rbrun::Workflow::Run.new(@session).done_count
    end
  end
end
```

- [ ] **Step 5: Run the test**

Run: `bin/rails test test/tools/rbrun/workflow_tools_test.rb`
Expected: PASS (6 tests).

- [ ] **Step 6: Commit**

```bash
git add app/tools/rbrun/tools/workflow_create.rb app/tools/rbrun/tools/validate_step.rb app/tools/rbrun/tools/cancel_workflow.rb app/tools/rbrun/tools/workflow_search.rb app/tools/rbrun/tools/use_workflow.rb test/tools/rbrun/workflow_tools_test.rb
git commit -m "feat(workflows): the five workflow tools"
```

---

### Task 5: WorkflowDecisionsController + job + route + card

**Files:**
- Create: `app/controllers/rbrun/workflow_decisions_controller.rb`, `app/jobs/rbrun/workflow_decision_turn_job.rb`
- Create: `app/components/rbrun/sessions/tools_validation/workflow_create/component.{rb,html.erb}`
- Modify: `config/routes.rb`
- Test: `test/controllers/rbrun/workflow_decision_flow_test.rb`

**Interfaces:**
- Consumes: `ResolvesGate` (`pending_gate`, `claim_gate!`, `record_gate_result`, `resume_turn`,
  `render_gate_band`), `Session#broadcast_workflow`, `Workflow`.
- Produces: route helper `workflow_decision_path(tool_use_id)` and the WorkflowCreate card — the two
  things `validate_tool_approvals!` will demand in Task 6.

- [ ] **Step 1: Add the route**

In `config/routes.rb`, after the `ask_user` route:

```ruby
  # Custom gate: workflow_create submits its Apply/Save/Cancel decision here.
  post "workflow_decision/:tool_use_id", to: "workflow_decisions#create", as: :workflow_decision
```

- [ ] **Step 2: Write the job**

```ruby
# app/jobs/rbrun/workflow_decision_turn_job.rb
module Rbrun
  # Resume a turn after the user decided a workflow_create gate. Off-request like the other gate jobs;
  # the nudge is the app's sentence, never a user message.
  class WorkflowDecisionTurnJob < ApplicationJob
    def perform(session_id, nudge) = Rbrun::Session.find(session_id).continue_turn!(nudge)
  end
end
```

- [ ] **Step 3: Write the controller**

```ruby
# app/controllers/rbrun/workflow_decisions_controller.rb
module Rbrun
  # The workflow_create gate endpoint. A frozen workflow_create tool_use row carries the proposed plan;
  # the user's Apply/Save/Cancel arrives here, is applied to a NEW durable Workflow (read off the FROZEN
  # plan — the agent proposed it, so the decision only chooses what to do with it), recorded as the
  # call's tool_result, and resumes the turn — via the shared ResolvesGate dance.
  class WorkflowDecisionsController < Rbrun::ApplicationController
    include Rbrun::ResolvesGate

    DECISIONS = %w[apply save cancel].freeze

    def create
      row = pending_gate
      decision = params[:decision].to_s
      return head(:unprocessable_entity) unless DECISIONS.include?(decision)
      return head :no_content unless claim_gate!(row, status: (decision == "cancel" ? "rejected" : "approved"))

      outcome = perform(decision, row.session, row.payload["input"] || {})
      record_gate_result(row, { "decision" => decision }.merge(outcome))
      resume_turn(row, WorkflowDecisionTurnJob, nudge_for(decision, outcome))
      render_gate_band(row)
    end

    private

    def perform(decision, session, plan)
      return { "created" => false } if decision == "cancel"

      workflow = create_workflow(session.tenant, plan)
      if decision == "apply"
        session.update!(workflow: workflow, workflow_status: "active")
        session.broadcast_workflow
      end
      { "created" => true, "workflow_id" => workflow.id, "label" => workflow.label, "bound" => decision == "apply" }
    end

    def create_workflow(tenant, plan)
      workflow = Rbrun::Workflow.new(label: plan["label"].to_s.strip.presence || "Untitled workflow",
                                     goal: plan["goal"], description: plan["description"])
      workflow[Rbrun.config.tenancy_key] = tenant
      workflow.save!
      Array(plan["steps"]).map(&:to_s).map(&:strip).reject(&:empty?).each_with_index do |title, i|
        workflow.steps.create!(position: i, title: title)
      end
      workflow
    end

    def nudge_for(decision, outcome)
      case decision
      when "apply"
        "The user applied the workflow \"#{outcome['label']}\" — it is now running in this conversation. " \
          "Work the steps in order; call validate_step when you finish each one."
      when "save"
        "The user saved the workflow \"#{outcome['label']}\" to the library but did NOT start it here. " \
          "Continue with the current task."
      else
        "The user declined to create the workflow. Proceed without one, or propose a revised plan."
      end
    end
  end
end
```

- [ ] **Step 4: Write the card component**

```ruby
# app/components/rbrun/sessions/tools_validation/workflow_create/component.rb
module Rbrun
  module Sessions
    module ToolsValidation
      module WorkflowCreate
        # The workflow_create gate card: the proposed plan + Apply/Save/Cancel while pending, a one-line
        # recap (off the tool_result) once decided.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

          def label = input["label"]
          def goal = input["goal"]
          def steps = Array(input["steps"])

          def decided? = !@call.approval_pending?

          def outcome
            @outcome ||= begin
              row = @call.session.messages.find_by(event_type: "tool_result", tool_use_id: tool_use_id)
              row&.payload&.dig("result") || {}
            end
          end

          def recap
            case outcome["decision"]
            when "apply" then "Applied — “#{outcome['label']}” is now running."
            when "save"  then "Saved “#{outcome['label']}” to the library."
            else "Declined — no workflow created."
            end
          end

          def submit_path = helpers.rbrun.workflow_decision_path(tool_use_id)
        end
      end
    end
  end
end
```

```erb
<%# app/components/rbrun/sessions/tools_validation/workflow_create/component.html.erb %>
<div class="border-t border-slate-200 p-3">
  <% if decided? %>
    <p class="text-sm text-slate-700"><%= recap %></p>
  <% else %>
    <p class="mb-1 text-xs font-medium text-slate-500">Proposed workflow</p>
    <p class="text-sm font-medium text-slate-800"><%= label %></p>
    <% if goal.present? %><p class="mb-2 text-xs text-slate-500"><%= goal %></p><% end %>
    <ol class="mb-3 flex flex-col gap-1 text-sm text-slate-700">
      <% steps.each_with_index do |title, i| %>
        <li class="flex items-baseline gap-2">
          <span class="text-slate-400"><%= i + 1 %>.</span><span><%= title %></span>
        </li>
      <% end %>
    </ol>
    <div class="flex items-center gap-2">
      <% %w[apply save cancel].each_with_index do |decision, i| %>
        <%= form_with url: submit_path, method: :post, class: "inline" do %>
          <button type="submit" name="decision" value="<%= decision %>"
                  class="<%= i.zero? ? 'bg-default-600 text-white hover:bg-default-500' : 'text-gray-700 ring-1 ring-inset ring-gray-300 hover:bg-gray-50' %> inline-flex items-center rounded-md px-2 py-1 text-xs font-medium">
            <%= decision.capitalize %>
          </button>
        <% end %>
      <% end %>
      <span class="ml-auto text-[11px] text-slate-400">Apply starts it here · Save keeps it in the library.</span>
    </div>
  <% end %>
</div>
```

- [ ] **Step 5: Write the failing integration test**

```ruby
# test/controllers/rbrun/workflow_decision_flow_test.rb
require "test_helper"

module Rbrun
  class WorkflowDecisionFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PLAN = { "label" => "Ship it", "goal" => "release v2",
             "steps" => [ "Bump", "Changelog", "Tag" ] }.freeze

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
      @session.messages.create!(role: "user", event_type: "text", content: "plan a release")
      @gate = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "wf1",
        approval_status: "pending", payload: { "name" => "workflow_create", "input" => PLAN })
    end

    def result_row = @session.messages.find_by(event_type: "tool_result", tool_use_id: "wf1")

    test "the card renders the plan + decision buttons (resolved by convention)" do
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "form[action=?]", "/rbrun/workflow_decision/wf1"
      assert_select "button[value=apply]"
      assert_select "button[value=save]"
      assert_select "button[value=cancel]"
    end

    test "apply creates the workflow, binds it, records + resumes" do
      assert_enqueued_with(job: Rbrun::WorkflowDecisionTurnJob) do
        assert_difference("Rbrun::Workflow.count", 1) do
          post "/rbrun/workflow_decision/wf1", params: { decision: "apply" }
        end
      end
      assert_response :success
      workflow = Rbrun::Workflow.order(:id).last
      assert_equal %w[Bump Changelog Tag], workflow.steps.map(&:title)
      assert_equal workflow.id, @session.reload.workflow_id
      assert @session.workflow_status_active?
      assert @gate.reload.approval_approved?
      assert_equal "apply", result_row.payload.dig("result", "decision")
    end

    test "save creates the workflow but does NOT bind it" do
      assert_difference("Rbrun::Workflow.count", 1) do
        post "/rbrun/workflow_decision/wf1", params: { decision: "save" }
      end
      assert_nil @session.reload.workflow_id
    end

    test "cancel creates nothing, marks rejected" do
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/workflow_decision/wf1", params: { decision: "cancel" }
      end
      assert @gate.reload.approval_rejected?
      assert_equal "cancel", result_row.payload.dig("result", "decision")
    end

    test "an unknown decision is rejected (422), nothing claimed" do
      post "/rbrun/workflow_decision/wf1", params: { decision: "nuke" }
      assert_response :unprocessable_entity
      assert @gate.reload.approval_pending?
    end

    test "a double submit is a no-op (the claim is the lock)" do
      post "/rbrun/workflow_decision/wf1", params: { decision: "save" }
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/workflow_decision/wf1", params: { decision: "apply" }
      end
    end
  end
end
```

- [ ] **Step 6: Run the test**

Run: `bin/rails test test/controllers/rbrun/workflow_decision_flow_test.rb`
Expected: PASS (6 tests). NOTE: the card resolves via `tools_validation_component` even though the tool
isn't registered yet — resolution is by name convention, not the roster.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/rbrun/workflow_decisions_controller.rb app/jobs/rbrun/workflow_decision_turn_job.rb app/components/rbrun/sessions/tools_validation/workflow_create config/routes.rb test/controllers/rbrun/workflow_decision_flow_test.rb
git commit -m "feat(workflows): decision gate controller, job, route, and create card"
```

---

### Task 6: Register tools + validate_step card + band + Stimulus

**Files:**
- Modify: `lib/rbrun/engine.rb` (register the 5 tools)
- Create: `app/components/rbrun/sessions/tools_validation/validate_step/component.{rb,html.erb}`
- Create: `app/views/rbrun/sessions/_workflow.html.erb`
- Modify: `app/components/rbrun/sessions/base/component.html.erb`
- Create: `app/javascript/rbrun/controllers/workflow_controller.js`
- Modify: `app/javascript/rbrun/rbrun.js`; rebuild the bundle
- Test: `test/tools/rbrun/workflow_registration_test.rb`, `test/controllers/rbrun/workflow_band_test.rb`

**Interfaces:**
- Consumes: everything from Tasks 1–5 (the WorkflowCreate card + `workflow_decision` route now exist, so
  `validate_tool_approvals!` passes with `WorkflowCreate` registered).
- Produces: the 5 tools in `Rbrun.tools` (manifest + `find`), the band, the validate_step card.

- [ ] **Step 1: Register the tools at boot**

In `lib/rbrun/engine.rb`, inside `config.after_initialize`, after the `register_tool(Rbrun::Tools::AskUser)`
line and BEFORE `validate_tool_approvals!`:

```ruby
      [ Rbrun::Tools::WorkflowCreate, Rbrun::Tools::ValidateStep, Rbrun::Tools::CancelWorkflow,
        Rbrun::Tools::WorkflowSearch, Rbrun::Tools::UseWorkflow ].each { |t| Rbrun.register_tool(t) }
```

- [ ] **Step 2: Boot check — the engine must still boot (custom_approval! enforced)**

Run: `bin/rails runner 'puts Rbrun.tools.map { |t| t.new.name }.sort.join(",")'`
Expected: includes `cancel_workflow,use_workflow,validate_step,workflow_create,workflow_search` — proves
boot passed `validate_tool_approvals!` (WorkflowCreate's card + route resolved).

- [ ] **Step 3: Write the validate_step card**

```ruby
# app/components/rbrun/sessions/tools_validation/validate_step/component.rb
module Rbrun
  module Sessions
    module ToolsValidation
      module ValidateStep
        # The validate_step gate card: the step being completed + the agent's summary, with the shared
        # yes/no approval actions while pending; the outcome once decided.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

          def summary = input["summary"]
          def decided? = !@call.approval_pending?
          def approved? = @call.approval_approved?

          def result
            @result ||= @call.session.messages.find_by(event_type: "tool_result", tool_use_id: tool_use_id)
                             &.payload&.dig("result") || {}
          end

          # After approval current_step has advanced, so read the completed step's title from the result.
          def step_title = result["step"].presence || Rbrun::Workflow::Run.new(@call.session).current_step&.title
        end
      end
    end
  end
end
```

```erb
<%# app/components/rbrun/sessions/tools_validation/validate_step/component.html.erb %>
<div class="border-t border-slate-200 p-3">
  <p class="text-xs font-medium text-slate-500">Step complete?</p>
  <p class="text-sm font-medium text-slate-800"><%= step_title %></p>
  <% if summary.present? %><p class="mb-2 text-xs text-slate-500"><%= summary %></p><% end %>
  <% if decided? %>
    <p class="text-sm text-slate-700"><%= approved? ? "Validated — step marked complete." : "Not yet — the agent will revise." %></p>
  <% else %>
    <div class="flex items-center gap-2 pt-1">
      <%= approval_actions(tool_use_id) %>
      <span class="ml-auto text-[11px] text-slate-400">Or ask for a change in the conversation.</span>
    </div>
  <% end %>
</div>
```

- [ ] **Step 4: Write the band partial**

```erb
<%# app/views/rbrun/sessions/_workflow.html.erb %>
<div id="workflow_<%= session.id %>">
  <% run = Rbrun::Workflow::Run.new(session) %>
  <% if session.workflow && !session.workflow_status_cancelled? %>
    <div class="mx-auto w-full max-w-3xl px-4 pt-3" data-controller="workflow"
         data-workflow-expanded-value="<%= helpers.cookies[:workflow_expanded] == '1' %>">
      <div class="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <button type="button" data-action="workflow#toggle"
                class="flex w-full items-center gap-2 px-3 py-2 text-left text-sm hover:bg-slate-50">
          <% if run.all_done? %>
            <%= lucide_icon("circle-check", class: "size-4 text-green-600") %>
          <% else %>
            <%= lucide_icon("loader", class: "size-4 text-slate-400") %>
          <% end %>
          <span class="font-medium text-slate-800"><%= run.current_step&.title || session.workflow.label %></span>
          <span class="ml-auto tabular-nums text-xs text-slate-500"><%= run.done_count %>/<%= run.total %></span>
          <%= lucide_icon("chevron-down", class: "size-4 text-slate-400", data: { "workflow-target": "chevron" }) %>
        </button>
        <div class="hidden border-t border-slate-100 px-3 py-2" data-workflow-target="body">
          <p class="mb-2 text-xs font-medium uppercase tracking-wide text-slate-400">Task progress</p>
          <ol class="flex flex-col gap-1.5">
            <% run.steps.each do |step| %>
              <li class="flex items-baseline gap-2 text-sm">
                <% if run.done?(step) %>
                  <%= lucide_icon("circle-check", class: "size-3.5 shrink-0 translate-y-0.5 text-green-600") %>
                  <span class="text-slate-500 line-through"><%= step.title %></span>
                <% else %>
                  <span class="mt-1 size-2 shrink-0 rounded-full bg-slate-300"></span>
                  <span class="text-slate-700"><%= step.title %></span>
                <% end %>
              </li>
            <% end %>
          </ol>
          <%= button_to "Cancel workflow", helpers.rbrun.session_message_path(session),
                params: { content: "Cancel the current workflow." },
                class: "mt-3 text-xs font-medium text-slate-500 hover:text-slate-700" %>
        </div>
      </div>
    </div>
  <% end %>
</div>
```

- [ ] **Step 5: Render the band above the composer**

In `app/components/rbrun/sessions/base/component.html.erb`, immediately BEFORE
`<div id="composer" …>` (after the scroll-region `</div>` that closes the `relative flex` block), add:

```erb
  <%= render "rbrun/sessions/workflow", session: session %>
```

- [ ] **Step 6: Write the Stimulus controller + register + rebuild**

```javascript
// app/javascript/rbrun/controllers/workflow_controller.js
import { Controller } from "@hotwired/stimulus"

// Collapse/expand the task-progress band. Client-only: the body is toggled and the choice persists in
// a cookie so a live band re-render (broadcast_workflow) keeps the user's open/closed preference.
export default class extends Controller {
  static targets = ["body", "chevron"]
  static values = { expanded: Boolean }

  connect() {
    this.apply(this.expandedValue)
  }

  toggle() {
    const open = this.bodyTarget.classList.toggle("hidden") === false
    this.apply(open)
    document.cookie = `workflow_expanded=${open ? "1" : ""}; path=/; max-age=${open ? 31536000 : 0}`
  }

  apply(open) {
    this.bodyTarget.classList.toggle("hidden", !open)
    if (this.hasChevronTarget) this.chevronTarget.classList.toggle("rotate-180", open)
  }
}
```

In `app/javascript/rbrun/rbrun.js`, add the import (after `CommandController`) and the register line
(after the `command` register):

```javascript
import WorkflowController from "./controllers/workflow_controller";
```
```javascript
application.register("workflow", WorkflowController);
```

Then rebuild the bundle:

Run: `bun run build`
Expected: writes `app/assets/builds/rbrun/rbrun.{css,js}` with no errors.

- [ ] **Step 7: Write the failing tests**

```ruby
# test/tools/rbrun/workflow_registration_test.rb
require "test_helper"

module Rbrun
  class WorkflowRegistrationTest < ActiveSupport::TestCase
    test "all five workflow tools are registered and findable" do
      %w[workflow_create validate_step cancel_workflow workflow_search use_workflow].each do |name|
        assert Rbrun::ApplicationTool.find(name), "#{name} not registered"
      end
    end

    test "the manifest marks the two gates as needing approval" do
      manifest = Rbrun::ApplicationTool.manifest.index_by { |e| e["name"] }
      assert manifest["workflow_create"]["needs_approval"]
      assert manifest["validate_step"]["needs_approval"]
      refute manifest["workflow_search"]["needs_approval"]
    end
  end
end
```

```ruby
# test/controllers/rbrun/workflow_band_test.rb
require "test_helper"

module Rbrun
  class WorkflowBandTest < ActionDispatch::IntegrationTest
    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
      @workflow = Rbrun::Workflow.new(label: "Ship")
      @workflow[Rbrun.config.tenancy_key] = "rbrun"
      @workflow.save!
      @s1 = @workflow.steps.create!(position: 0, title: "one")
      @s2 = @workflow.steps.create!(position: 1, title: "two")
    end

    test "no workflow → the band wrapper renders empty (a broadcast target)" do
      get "/rbrun/c/#{@session.id}"
      assert_select "#workflow_#{@session.id}"
      assert_select "#workflow_#{@session.id} [data-controller=workflow]", false
    end

    test "bound + active → the band shows steps and the counter" do
      @session.update!(workflow: @workflow, workflow_status: "active")
      @session.workflow_step_completions.create!(workflow_step: @s1, completed_at: Time.current)
      get "/rbrun/c/#{@session.id}"
      assert_select "#workflow_#{@session.id} [data-controller=workflow]"
      assert_select "#workflow_#{@session.id}", /1\/2/
      assert_select "form[action=?]", "/rbrun/c/#{@session.id}" # the cancel button posts to the composer endpoint
    end

    test "cancelled → the band hides" do
      @session.update!(workflow: @workflow, workflow_status: "cancelled")
      get "/rbrun/c/#{@session.id}"
      assert_select "#workflow_#{@session.id} [data-controller=workflow]", false
    end
  end
end
```

- [ ] **Step 8: Run the tests + the full suite**

Run: `bin/rails test test/tools/rbrun/workflow_registration_test.rb test/controllers/rbrun/workflow_band_test.rb`
Expected: PASS. Then `bin/rails test` — the whole suite green (boot with the new tools registered).

- [ ] **Step 9: Commit**

```bash
git add lib/rbrun/engine.rb app/components/rbrun/sessions/tools_validation/validate_step app/views/rbrun/sessions/_workflow.html.erb app/components/rbrun/sessions/base/component.html.erb app/javascript/rbrun/controllers/workflow_controller.js app/javascript/rbrun/rbrun.js app/assets/builds/rbrun/rbrun.js app/assets/builds/rbrun/rbrun.css test/tools/rbrun/workflow_registration_test.rb test/controllers/rbrun/workflow_band_test.rb
git commit -m "feat(workflows): register tools, validate_step card, progress band, Stimulus"
```

---

### Task 7: The `workflow-creator` built-in skill

**Files:**
- Create: `app/skills/workflow-creator/SKILL.md`
- Modify: `app/services/rbrun/skill_seeder.rb` (seed engine built-in skills)
- Test: `test/services/rbrun/workflow_skill_seed_test.rb`

**Interfaces:**
- Consumes: `SkillSeeder.authored_from_config`, `SkillArchive.read_dir`, `Skill` model, `seed_at_boot!`.
- Produces: a seeded `Rbrun::Skill` with slug `workflow-creator` for the self-host tenant.

- [ ] **Step 1: Write SKILL.md**

```markdown
<!-- app/skills/workflow-creator/SKILL.md -->
---
name: workflow-creator
description: How to run multi-step tasks as user-guided workflows — propose a plan, then complete one step at a time with the user validating each.
---

# Running work as a workflow

A **workflow** turns a multi-step task into a task-progress band the user watches advance. Use it to give
the user visibility and control over anything with a clear goal and more than one step.

## When to start one

- The task has a clear goal and **more than one step** — never for a single step.
- First call `workflow_search` to reuse an existing workflow. If one fits, `use_workflow` it.
- Otherwise call `workflow_create` with a short `label`, a one-line `goal`, and ordered `steps`
  (short imperative titles). The run pauses; the **user** chooses Apply, Save, or Cancel — never assume.

## Running the steps

- Work **one step at a time**, in order. Do the current step's actual work first.
- Only then call `validate_step` with a one-line `summary` of what you did. The run pauses for the user's
  approval; on approval the band advances, on refusal nothing is recorded — read their feedback and redo
  the step.
- One workflow per conversation: calling `workflow_create` again replaces the current binding.

## Cancelling

If the user asks to stop, call `cancel_workflow` and confirm. The workflow itself is kept; only this run
stops.
```

- [ ] **Step 2: Seed engine built-in skills**

In `app/services/rbrun/skill_seeder.rb`, modify `authored_from_config` to prepend engine built-ins, and
`seed_at_boot!` to run whenever built-ins exist. Add a `BUILTIN_DIR` constant and a `builtin_authored`
method. Change the top of `authored_from_config` to seed built-ins first:

```ruby
    BUILTIN_DIR = Rbrun::Engine.root.join("app/skills")

    # Engine-shipped skills (e.g. workflow-creator) — always seeded, like a built-in tool.
    def self.builtin_authored
      return [] unless Dir.exist?(BUILTIN_DIR)

      Dir.glob(BUILTIN_DIR.join("*").to_s).select { |d| File.directory?(d) }.sort.map do |folder|
        slug = File.basename(folder)
        { slug: slug, name: slug, files: Rbrun::SkillArchive.read_dir(folder), source: :file }
      end
    end
```

In `authored_from_config`, change the first line from `authored = []` to:

```ruby
      authored = builtin_authored
```

In `seed_at_boot!`, change the early-return guard from:

```ruby
      return unless Rbrun.config.skills_path.present? || Rbrun.config.skills.any?
```
to:
```ruby
      return unless BUILTIN_DIR.exist? || Rbrun.config.skills_path.present? || Rbrun.config.skills.any?
```

- [ ] **Step 3: Write the failing test**

```ruby
# test/services/rbrun/workflow_skill_seed_test.rb
require "test_helper"

module Rbrun
  class WorkflowSkillSeedTest < ActiveSupport::TestCase
    test "the workflow-creator built-in is among the authored sources" do
      slugs = Rbrun::SkillSeeder.authored_from_config(Rbrun.config).map { |s| s[:slug] }
      assert_includes slugs, "workflow-creator"
    end

    test "seeding creates the workflow-creator skill with a current version" do
      Rbrun::SkillSeeder.from_config(Rbrun.config, tenant: "rbrun").call
      skill = Rbrun::Skill.for_tenant("rbrun").find_by(slug: "workflow-creator")
      assert skill, "skill seeded"
      assert skill.current_version, "has a current version to stage"
    end
  end
end
```

- [ ] **Step 4: Run the test + full suite**

Run: `bin/rails test test/services/rbrun/workflow_skill_seed_test.rb && bin/rails test`
Expected: PASS; whole suite green.

- [ ] **Step 5: Commit**

```bash
git add app/skills/workflow-creator/SKILL.md app/services/rbrun/skill_seeder.rb test/services/rbrun/workflow_skill_seed_test.rb
git commit -m "feat(workflows): workflow-creator built-in skill + engine skill seeding"
```

---

## Self-Review

- **Spec coverage:** models + Session columns (T1–2) ✓ · Run (T3) ✓ · 5 tools (T4) ✓ · decision
  controller/job/route/card (T5) ✓ · registration + validate_step card + band + Stimulus + cancel button
  (T6) ✓ · skill (T7) ✓. Out-of-scope (library, dogfood) correctly omitted.
- **Boot-enforcement ordering:** `register_tool(WorkflowCreate)` is in T6, AFTER its card (T5) + route
  (T5) exist — boot can't fail. Verified explicitly in T6 Step 2.
- **Band-wipe hazard:** the band is a sibling ABOVE `#composer` with its own `#workflow_<id>` target, so
  `broadcast_composer`'s wholesale `#composer` replace never touches it. `broadcast_workflow` repaints it
  independently.
- **Type consistency:** `Workflow::Run` API (`current_step`, `done_count`, `total`, `all_done?`,
  `done?`) is identical across tools, cards, band. Tool results all `{ "data" => … }` / `{ "error" => … }`.
  `workflow_decision` route name matches `custom_approval! submit: :workflow_decision`.
- **Portable search:** `LIKE` with `COALESCE` + `sanitize_sql_like`, blank → `none`; tenant via
  `for_tenant`. No pg_search.
```
