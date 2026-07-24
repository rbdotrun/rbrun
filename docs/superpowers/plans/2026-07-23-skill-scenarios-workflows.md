# Skill Editor — Plan 2: scenarios = skill-bound workflows + run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A skill's scenarios/examples ARE `Rbrun::Workflow`s bound to the skill (`skill_id` + example `prompt` + `WorkflowStep`s). Author them through a nested form (WorkflowStep rows with real validation + error surfacing), **▶ Run** one to replay it in an autonomous `:skill_scenario` session that self-validates each step and captures the produced artifact as the scenario's showcase. `SkillScenario` retires. The `scenarios` dogfood runs the whole loop against real Claude + Daytona and prints green.

**Architecture:** Collapse `SkillScenario` into `Workflow`: add `skill_id`, `prompt`, `showcase_artifact_version_id`. `Skill has_many :workflows`. The runtime already binds a session to a `Workflow` and self-validates its `WorkflowStep`s, so `SkillScenarioRun` just binds a skill-bound workflow, replays its `prompt`, and writes the produced `ArtifactVersion` into the workflow's showcase. The nested form uses `accepts_nested_attributes_for :steps` (rejecting only all-blank rows, so a title-blank/description-present row surfaces a validation error) plus a tiny `nested-fields` Stimulus controller for add/remove.

**Tech Stack:** Rails 8.1 engine, Ruby 3.4.4, ViewComponent primitives via `component(...)`, Stimulus (bun-built), Capybara/Cuprite system tests, real Claude SDK + Daytona for the dogfood.

## Global Constraints

- Reach every component through `component("<name>", …)` / `custom(...)` — NEVER `render(Rbrun::…::Component.new)` or a raw `<input>`/`<select>`/`<button>` in a view.
- `Rbrun::Workflow` stays the general model; the three new columns are nullable (set only when skill-bound). A nil `skill_id` is a plain conversation workflow — its behavior must not change.
- Do not swallow errors — invalid saves re-render `:unprocessable_entity` with per-field errors.
- Idempotency: `SkillScenarios.ingest` find-or-creates one workflow per `[tenant, skill, label]` and rebuilds its steps (invariant 11).
- The template workflow is the skill's — `SkillScenarioRun` reaps the session + worktree but NEVER destroys the workflow.
- Engine migrations in `db/migrate/` (timestamped) → `bin/rails db:migrate` updates `test/dummy/db/schema.rb`.
- After JS/Tailwind changes run `bun run build` (regenerates `app/assets/builds/rbrun/rbrun.{js,css}`) so system tests see them.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: `Workflow` becomes scenario-capable

**Files:**
- Create: `db/migrate/20260724100000_add_scenario_columns_to_rbrun_workflows.rb`
- Modify: `app/models/rbrun/workflow.rb`, `app/models/rbrun/workflow_step.rb`, `app/models/rbrun/skill.rb`
- Test: `test/models/rbrun/workflow_test.rb`, `test/models/rbrun/skill_test.rb`

**Interfaces:**
- Produces: `Workflow#skill` (optional), `Workflow#prompt`, `Workflow#showcase_artifact_version` (optional); `Workflow.scenarios` scope (`where.not(skill_id: nil)`); `accepts_nested_attributes_for :steps` (allow_destroy, rejects all-blank rows); `Skill#workflows`.

- [ ] **Step 1: Write failing model tests**

Add to `test/models/rbrun/workflow_test.rb`:

```ruby
test "a workflow can belong to a skill and carry a prompt (a scenario)" do
  skill = Rbrun::Skill.create!(tenant: "acme", slug: "s", name: "S")
  wf = Rbrun::Workflow.create!(tenant: "acme", label: "Case", skill:, prompt: "do the thing")
  assert_equal skill, wf.skill
  assert_includes Rbrun::Workflow.scenarios, wf
end

test "a plain workflow has no skill and is excluded from scenarios" do
  wf = Rbrun::Workflow.create!(tenant: "acme", label: "Plain")
  assert_nil wf.skill
  refute_includes Rbrun::Workflow.scenarios, wf
end

test "nested steps_attributes build ordered steps; a fully blank row is rejected" do
  wf = Rbrun::Workflow.create!(tenant: "acme", label: "W", steps_attributes: [
    { position: 1, title: "One", description: "prove one" },
    { position: 2, title: "",    description: "" } # all-blank → rejected
  ])
  assert_equal 1, wf.steps.count
  assert_equal "One", wf.steps.first.title
end

test "a step with a description but no title is INVALID (surfaces a nested error)" do
  wf = Rbrun::Workflow.new(tenant: "acme", label: "W", steps_attributes: [
    { position: 1, title: "", description: "has content but no title" }
  ])
  refute wf.valid?
  assert wf.steps.first.errors[:title].present?
end
```

Add to `test/models/rbrun/skill_test.rb`:

```ruby
test "a skill has_many workflows (its scenarios)" do
  skill = Rbrun::Skill.create!(tenant: "acme", slug: "s", name: "S")
  wf = Rbrun::Workflow.create!(tenant: "acme", label: "Case", skill:, prompt: "go")
  assert_includes skill.workflows, wf
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/models/rbrun/workflow_test.rb test/models/rbrun/skill_test.rb`
Expected: FAIL — no `skill` association / `scenarios` scope / nested attrs.

- [ ] **Step 3: Migration**

Create `db/migrate/20260724100000_add_scenario_columns_to_rbrun_workflows.rb`:

```ruby
class AddScenarioColumnsToRbrunWorkflows < ActiveRecord::Migration[8.1]
  # A skill-bound workflow IS that skill's scenario/example: skill_id (present ⇒ scenario), an example
  # prompt to replay, and a pointer to the artifact its last run produced (the showcase). All nullable —
  # a plain conversation workflow leaves them nil.
  def change
    add_reference :rbrun_workflows, :skill, null: true, foreign_key: { to_table: :rbrun_skills }
    add_column    :rbrun_workflows, :prompt, :text
    add_reference :rbrun_workflows, :showcase_artifact_version, null: true,
                  foreign_key: { to_table: :rbrun_artifact_versions }
  end
end
```

- [ ] **Step 4: Wire the models**

`app/models/rbrun/workflow.rb` — add associations + scope + nested attrs (keep the existing `has_many :steps` line, add `inverse_of: :workflow` to it):

```ruby
    belongs_to :skill, class_name: "Rbrun::Skill", optional: true
    belongs_to :showcase_artifact_version, class_name: "Rbrun::ArtifactVersion", optional: true

    has_many :steps, -> { order(:position) }, class_name: "Rbrun::WorkflowStep",
             inverse_of: :workflow, dependent: :destroy

    accepts_nested_attributes_for :steps, allow_destroy: true,
      reject_if: ->(a) { a[:title].blank? && a[:description].blank? }

    # Skill-bound workflows are a skill's scenarios/examples.
    scope :scenarios, -> { where.not(skill_id: nil) }
```

(Replace the existing `has_many :steps …` line with the `inverse_of:` version above; do not duplicate it.)

`app/models/rbrun/workflow_step.rb` — add `inverse_of` so nested attrs associate:

```ruby
    belongs_to :workflow, class_name: "Rbrun::Workflow", inverse_of: :steps
```

`app/models/rbrun/skill.rb` — add, near the other associations:

```ruby
    has_many :workflows, class_name: "Rbrun::Workflow", dependent: :destroy
```

- [ ] **Step 5: Migrate + run tests**

Run: `bin/rails db:migrate && bin/rails test test/models/rbrun/workflow_test.rb test/models/rbrun/skill_test.rb`
Expected: PASS. Verify `test/dummy/db/schema.rb` shows `skill_id`, `prompt`, `showcase_artifact_version_id` on `rbrun_workflows`.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260724100000_add_scenario_columns_to_rbrun_workflows.rb \
        app/models/rbrun/workflow.rb app/models/rbrun/workflow_step.rb app/models/rbrun/skill.rb \
        test/models/rbrun/workflow_test.rb test/models/rbrun/skill_test.rb test/dummy/db/schema.rb
git commit -m "feat(workflows): a workflow can belong to a skill (a scenario) + nested steps

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `SkillScenarioRun` binds a skill-bound workflow + captures the showcase

**Files:**
- Modify: `app/services/rbrun/skill_scenario_run.rb`
- Test: `test/services/rbrun/skill_scenario_run_test.rb`

**Interfaces:**
- Consumes: a skill-bound `Rbrun::Workflow` (Task 1); `Session#kind` (Plan 1).
- Produces: `Rbrun::SkillScenarioRun.run(workflow, tenant:, runtime: nil) → { workflow:, session:, steps:, done:, total:, pass:, showcase: }`. Binds the workflow to a `:skill_scenario` session, replays `workflow.prompt`, self-validates, sets `workflow.showcase_artifact_version` to the artifact produced during the run. Reaps the session + worktree; never destroys the workflow.

- [ ] **Step 1: Rewrite the test to the workflow signature**

Replace `test/services/rbrun/skill_scenario_run_test.rb`'s `setup` and the runtimes with a workflow-based setup. Keep the `SelfValidatingRuntime`/`StuckRuntime` fakes; add a `ProducesArtifactRuntime` that writes a file and calls `save_artifact` through the real tool path. New setup:

```ruby
    setup do
      @skill = Rbrun::Skill.create!(tenant: "acme", slug: "create-skill", name: "Create Skill")
      @workflow = Rbrun::Workflow.create!(
        tenant: "acme", skill: @skill, label: "Two steps", goal: "prove it", prompt: "do the thing",
        steps_attributes: [
          { position: 1, title: "Step one", description: "prove one" },
          { position: 2, title: "Step two", description: "prove two" }
        ]
      )
    end
```

Update the existing tests to call `Rbrun::SkillScenarioRun.run(@workflow, tenant: "acme", runtime: …)` and read `record[:total]/:done/:pass/:steps` (step labels come from `step[:label]` = the WorkflowStep title). Add:

```ruby
    class ProducesArtifactRuntime
      def initialize = @n = 0
      def run(prompt:, tool_handler:, on_event:, system: nil, tools: [], skills: nil, mcp: nil, resume: nil, auto: nil, cwd: nil)
        @n += 1
        # Validate the step AND, on the first turn, produce a real artifact via the tool path.
        if @n == 1
          tool_handler.call({ id: "w1", name: "save_artifact", args: { path: "out.md", name: "Result" } })
        end
        tool_handler.call({ id: "v#{@n}", name: "validate_step", args: { summary: "did it" } })
        on_event.call({ "type" => "result", "session_id" => "sdk-#{@n}" })
      end
    end

    test "captures the produced artifact as the workflow's showcase" do
      # The tool reads out.md from the box — write it into the Local sandbox first via a hook runtime.
      writer = Class.new(ProducesArtifactRuntime) do
        def run(**kw)
          # session's sandbox is reachable through the tool call; ensure the file exists first.
          super
        end
      end
      # Pre-seed the file so save_artifact can read it.
      Rbrun::SkillScenarioRun.stub_before_run = ->(session) { session.sandbox.write("out.md", "# result\n") }
      record = Rbrun::SkillScenarioRun.run(@workflow, tenant: "acme", runtime: ProducesArtifactRuntime.new)
      assert record[:showcase].present?, "showcase artifact captured"
      assert_equal record[:showcase], @workflow.reload.showcase_artifact_version
    end
```

NOTE: rather than a `stub_before_run` hook, prefer writing the file inside the fake runtime using the session it is handed. If the runtime signature does not expose the session, seed the file by making `ProducesArtifactRuntime#run` accept the sandbox via a closure set in the test. Keep it simple: in the test, before calling `.run`, you cannot reach the session (created inside run). So instead assert showcase capture with a DIRECT unit on a helper — see Step 3's `capture_showcase`. Replace the above test with:

```ruby
    test "capture_showcase sets the workflow's showcase to the latest artifact version on the session" do
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "rbrun/scenarios", bare: true)
      session = wt.sessions.create!(tenant: "acme", kind: :skill_scenario, workflow: @workflow)
      lead = session.messages.create!(role: "user", event_type: "text", content: @workflow.prompt)
      version = Rbrun::Artifact.append_version!(tenant: "acme", message: lead,
                  io: StringIO.new("# result\n"), filename: "out.md", name: "Result")

      Rbrun::SkillScenarioRun.new(@workflow, tenant: "acme").send(:capture_showcase, session)
      assert_equal version, @workflow.reload.showcase_artifact_version
    ensure
      wt&.sandbox&.destroy! rescue nil
    end
```

(Add `require "stringio"` at the top of the test if not present.)

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/services/rbrun/skill_scenario_run_test.rb`
Expected: FAIL — `run` still takes a scenario / no `capture_showcase`.

- [ ] **Step 3: Rewrite the service**

Rewrite `app/services/rbrun/skill_scenario_run.rb` to take a workflow:

```ruby
module Rbrun
  # Replays a skill's scenario (a skill-bound Workflow) as a SELF-VALIDATING run. It binds the workflow
  # to an AUTONOMOUS :skill_scenario session (auto mode → the gate never parks, so the agent
  # self-validates via validate_step without a human), replays the workflow's OWN prompt, nudges until
  # every step is validated or the run stalls, and captures the produced artifact as the workflow's
  # showcase. The verdict is the agent's. The box + session are reaped in `ensure`; the workflow (the
  # skill's template) is NEVER destroyed.
  class SkillScenarioRun
    GUARD = 12

    def self.run(workflow, tenant:, runtime: nil) = new(workflow, tenant:, runtime:).run

    def initialize(workflow, tenant:, runtime: nil)
      @workflow = workflow
      @tenant = tenant
      @runtime = runtime
    end

    def run
      worktree = Rbrun::Worktree.create!(tenant: @tenant, repo: "rbrun/scenarios", bare: true)
      session  = worktree.sessions.create!(tenant: @tenant, auto: true, kind: :skill_scenario,
                                           workflow: @workflow, workflow_status: "active",
                                           preferred_skills: [ @workflow.skill.slug ])
      begin
        session.run_turn(@workflow.prompt, runtime: @runtime)
        advance(session)
        capture_showcase(session)
        record(session.reload)
      ensure
        begin
          session.sandbox.destroy!
        rescue StandardError
          nil
        end
        worktree.destroy!
      end
    end

    private

      def advance(session)
        prev = -1
        idle = 0
        (@workflow.steps.size + GUARD).times do
          run = Rbrun::Workflow::Run.new(session.reload)
          break if run.all_done?

          idle = run.done_count > prev ? 0 : idle + 1
          break if idle >= 2

          prev = run.done_count
          session.run_turn("Continue the workflow: pick up at the next step you have not validated.", runtime: @runtime)
        end
      end

      # The artifact produced during this run (attributed to one of the session's messages) becomes the
      # workflow's showcase. Persisted before reaping; the version survives the session's deletion.
      def capture_showcase(session)
        version = Rbrun::ArtifactVersion.where(message: session.messages).order(:id).last
        @workflow.update!(showcase_artifact_version: version) if version
      end

      def record(session)
        run = Rbrun::Workflow::Run.new(session)
        steps = @workflow.steps.map do |step|
          { label: step.title, description: step.description,
            done: session.workflow_step_completions.exists?(workflow_step: step) }
        end
        { workflow: @workflow, session:, steps:, showcase: @workflow.showcase_artifact_version,
          done: run.done_count, total: run.total, pass: run.all_done? }
      end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bin/rails test test/services/rbrun/skill_scenario_run_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/rbrun/skill_scenario_run.rb test/services/rbrun/skill_scenario_run_test.rb
git commit -m "feat(scenarios): SkillScenarioRun binds a skill-bound workflow + captures showcase

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Retire `SkillScenario`; ingest → skill-bound workflows; fix the dogfood task

**Files:**
- Delete: `app/models/rbrun/skill_scenario.rb`
- Create: `db/migrate/20260724110000_drop_rbrun_skill_scenarios.rb`
- Modify: `app/services/rbrun/skill_scenarios.rb` (ingest → workflows)
- Modify: `lib/tasks/rbrun/dogfood/scenarios.rake`
- Test: `test/services/rbrun/skill_scenarios_test.rb`

**Interfaces:**
- Consumes: Task 1's `Skill#workflows` + nested steps.
- Produces: `SkillScenarios.ingest(skill, dir)` find-or-creates one skill-bound `Workflow` per `[tenant, skill, label]` from `scenarios/*.yml` (prompt → `prompt`, description → `goal`, steps → `WorkflowStep`s), idempotent; `ingest_all` unchanged in signature.

- [ ] **Step 1: Rewrite the ingest test**

Rewrite `test/services/rbrun/skill_scenarios_test.rb`'s first two tests to assert workflows:

```ruby
    test "ingest upserts one skill-bound workflow keyed [skill, label], idempotent" do
      with_scenarios(SCENARIO) do |dir|
        assert_equal 1, Rbrun::SkillScenarios.ingest(@skill, dir)
        assert_equal 1, Rbrun::SkillScenarios.ingest(@skill, dir) # idempotent

        wf = @skill.workflows.for_tenant("acme").find_by!(label: "Builds a dad-joke skill")
        assert_equal "Make me a skill that tells a dad joke.", wf.prompt
        assert_equal 2, wf.steps.count
        assert_equal "Author the folder", wf.steps.first.title
        assert_equal 1, @skill.workflows.count
      end
    end

    test "a blank-label scenario is skipped" do
      with_scenarios("description: no label\nprompt: hi\n") do |dir|
        assert_equal 0, Rbrun::SkillScenarios.ingest(@skill, dir)
      end
    end
```

(The "scenarios/ excluded from archive" test stays unchanged.)

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/services/rbrun/skill_scenarios_test.rb`
Expected: FAIL — ingest still writes `SkillScenario`.

- [ ] **Step 3: Rewrite `SkillScenarios.upsert`**

In `app/services/rbrun/skill_scenarios.rb`, replace `upsert` to find-or-create a skill-bound workflow and rebuild its steps:

```ruby
    def upsert(skill, path)
      data  = YAML.safe_load(File.read(path)) || {}
      label = data["label"].to_s.strip
      return false if label.blank?

      steps = Array(data["steps"]).each_with_index.map do |s, i|
        { position: i + 1, title: s["label"].to_s, description: s["description"].to_s }
      end

      workflow = skill.workflows.for_tenant(skill.tenant).find_or_initialize_by(label:)
      workflow.assign_attributes(prompt: data["prompt"].to_s, goal: data["description"].to_s)
      workflow.steps.destroy_all if workflow.persisted? # idempotent rebuild
      workflow.steps.build(steps)
      workflow.save!
      true
    end
```

(Remove `attachments` handling — the merged model drops it.)

- [ ] **Step 4: Fix the dogfood task**

In `lib/tasks/rbrun/dogfood/scenarios.rake`, change the run loop to iterate the skills' scenario workflows:

Replace the block from `scenarios = Rbrun::SkillScenario…` to the end with:

```ruby
    scenarios = Rbrun::Workflow.for_tenant(tenant).scenarios.includes(:skill).order(:skill_id, :label)
    if scenarios.empty?
      puts "no scenarios seeded — add scenarios/*.yml under a skill folder."
      next
    end

    passed = 0
    scenarios.each do |workflow|
      dog.header "#{workflow.skill.slug} · #{workflow.label}"
      record = Rbrun::SkillScenarioRun.run(workflow, tenant:)
      passed += 1 if record[:pass]
      record[:steps].each { |step| dog.ok step[:label], step[:done] }
      dog.info "showcase", (record[:showcase] ? "artifact ##{record[:showcase].artifact_id} v#{record[:showcase].number}" : "—")
      mark = record[:pass] ? "✓" : "✗"
      puts format("%s  %s · %-32s  %s/%s", mark, workflow.skill.slug, workflow.label, record[:done], record[:total])
    end

    puts "\n— #{passed}/#{scenarios.size} scenarios passed"
```

- [ ] **Step 5: Delete the model + migration**

Delete `app/models/rbrun/skill_scenario.rb`. Create `db/migrate/20260724110000_drop_rbrun_skill_scenarios.rb`:

```ruby
class DropRbrunSkillScenarios < ActiveRecord::Migration[8.1]
  # Scenarios collapsed into skill-bound Rbrun::Workflow (Plan 2). The YAML seeds re-ingest into
  # workflows idempotently, so no data migration is needed.
  def up = drop_table :rbrun_skill_scenarios
  def down
    create_table :rbrun_skill_scenarios do |t|
      t.string  :tenant, null: false
      t.integer :skill_id, null: false
      t.string  :label, null: false
      t.text    :prompt, null: false
      t.text    :description
      t.json    :steps, null: false, default: []
      t.json    :attachments, null: false, default: []
      t.timestamps
      t.index %i[tenant skill_id label], unique: true, name: "idx_rbrun_skill_scenarios_unique"
      t.index :skill_id
    end
  end
end
```

- [ ] **Step 6: Migrate + run the affected suites**

Run: `bin/rails db:migrate && bin/rails test test/services/rbrun/skill_scenarios_test.rb test/services/rbrun/skill_scenario_run_test.rb`
Expected: PASS. Confirm `rbrun_skill_scenarios` is gone from `test/dummy/db/schema.rb`.

- [ ] **Step 7: Full suite (catch any lingering SkillScenario refs)**

Run: `bin/rails test`
Expected: PASS. If anything references `Rbrun::SkillScenario`, fix it (grep `SkillScenario` across `app/ lib/ test/`).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor(scenarios): retire SkillScenario — a scenario IS a skill-bound workflow

Ingest find-or-creates one skill-bound Workflow per scenario YAML (idempotent
step rebuild); the dogfood board iterates Workflow.scenarios. Drops the
rbrun_skill_scenarios table.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: the scenario UI — nested form + ▶ Run

**Files:**
- Modify: `config/routes.rb` (nested `resources :workflows` under `:skills` + member `run`)
- Create: `app/controllers/rbrun/workflows_controller.rb`
- Create: `app/jobs/rbrun/skill_scenario_run_job.rb`
- Create: `app/views/rbrun/workflows/new.html.erb`, `edit.html.erb`, `_form.html.erb`, `_step_fields.html.erb`
- Create: `app/javascript/rbrun/controllers/nested_fields_controller.js`
- Modify: `app/javascript/rbrun/rbrun.js` (register it)
- Modify: `app/views/rbrun/skills/_form.html.erb` (list the skill's scenarios + New/Run/Edit)
- Test: `test/controllers/rbrun/workflows_flow_test.rb`

**Interfaces:**
- Consumes: `Skill#workflows`, nested `steps_attributes` (Task 1); `SkillScenarioRun` (Task 2).
- Produces: routes `new_skill_workflow`, `skill_workflow` (create/update/destroy), `edit_skill_workflow`, `run_skill_workflow`; `WorkflowsController`; `SkillScenarioRunJob.perform_later(workflow_id, tenant:)`.

- [ ] **Step 1: Write failing controller tests**

Create `test/controllers/rbrun/workflows_flow_test.rb` (reuse the login from other flow tests, tenant `rbrun`):

```ruby
require "test_helper"

module Rbrun
  class WorkflowsFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @skill = Rbrun::Skill.create!(tenant: "rbrun", slug: "changelog", name: "Changelog")
    end

    test "GET new renders a scenario form with one step row" do
      get "/rbrun/skills/changelog/workflows/new"
      assert_response :success
      assert_select "input[name=?]", "workflow[label]"
      assert_select "input[name=?]", "workflow[prompt]"
      assert_select "input[name^=?]", "workflow[steps_attributes]"
    end

    test "POST creates a skill-bound workflow with steps" do
      assert_difference("@skill.workflows.count", 1) do
        post "/rbrun/skills/changelog/workflows", params: { workflow: {
          label: "Weekly notes", prompt: "summarize the week",
          steps_attributes: { "0" => { position: 1, title: "Collect", description: "gather PRs" } }
        } }
      end
      wf = @skill.workflows.order(:id).last
      assert_equal "Weekly notes", wf.label
      assert_equal 1, wf.steps.count
      assert_redirected_to "/rbrun/skills/changelog/edit"
    end

    test "POST with a blank workflow label re-renders unprocessable_entity" do
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/skills/changelog/workflows", params: { workflow: { label: "", prompt: "x" } }
      end
      assert_response :unprocessable_entity
    end

    test "POST with a step that has a description but no title surfaces a nested error" do
      assert_no_difference("Rbrun::Workflow.count") do
        post "/rbrun/skills/changelog/workflows", params: { workflow: {
          label: "Has bad step", prompt: "x",
          steps_attributes: { "0" => { position: 1, title: "", description: "content, no title" } }
        } }
      end
      assert_response :unprocessable_entity
      assert_select ".text-red-600" # a field error is rendered
    end

    test "▶ Run enqueues the scenario run" do
      wf = @skill.workflows.create!(tenant: "rbrun", label: "Case", prompt: "go")
      assert_enqueued_with(job: Rbrun::SkillScenarioRunJob) do
        post "/rbrun/skills/changelog/workflows/#{wf.id}/run"
      end
      assert_redirected_to "/rbrun/skills/changelog/edit"
    end

    test "DELETE removes a scenario" do
      wf = @skill.workflows.create!(tenant: "rbrun", label: "Case", prompt: "go")
      assert_difference("Rbrun::Workflow.count", -1) do
        delete "/rbrun/skills/changelog/workflows/#{wf.id}"
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/rbrun/workflows_flow_test.rb`
Expected: FAIL — no routes/controller.

- [ ] **Step 3: Routes**

In `config/routes.rb`, extend the skills block:

```ruby
  resources :skills, param: :slug, only: %i[index new create edit update] do
    member { post :reconcile }
    resources :workflows, only: %i[new create edit update destroy] do
      member { post :run }
    end
  end
```

- [ ] **Step 4: The job**

Create `app/jobs/rbrun/skill_scenario_run_job.rb`:

```ruby
module Rbrun
  # Runs a scenario (skill-bound workflow) off the request: a real autonomous, self-validating run.
  class SkillScenarioRunJob < ApplicationJob
    def perform(workflow_id, tenant:)
      workflow = Rbrun::Workflow.for_tenant(tenant).scenarios.find(workflow_id)
      Rbrun::SkillScenarioRun.run(workflow, tenant:)
    end
  end
end
```

(Confirm the engine's base job class name — likely `Rbrun::ApplicationJob`; match the other jobs in `app/jobs/rbrun/`.)

- [ ] **Step 5: The controller**

Create `app/controllers/rbrun/workflows_controller.rb`:

```ruby
module Rbrun
  # A skill's scenarios — skill-bound Rbrun::Workflows authored through a nested form and replayed by
  # ▶ Run as self-validating autonomous runs.
  class WorkflowsController < Rbrun::ApplicationController
    before_action :set_skill

    def new
      @workflow = @skill.workflows.build(tenant: current_tenant)
      @workflow.steps.build(position: 1)
    end

    def create
      @workflow = @skill.workflows.build(workflow_params.merge(tenant: current_tenant))
      if @workflow.save
        redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario saved."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @workflow = find_workflow
    end

    def update
      @workflow = find_workflow
      if @workflow.update(workflow_params)
        redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      find_workflow.destroy!
      redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario removed."
    end

    def run
      Rbrun::SkillScenarioRunJob.perform_later(find_workflow.id, tenant: current_tenant)
      redirect_to rbrun.edit_skill_path(@skill.slug), notice: "Scenario run started."
    end

    private

      def set_skill = @skill = Rbrun::Skill.for_tenant(current_tenant).find_by!(slug: params[:skill_slug])
      def find_workflow = @skill.workflows.find(params[:id])

      def workflow_params
        params.require(:workflow).permit(:label, :prompt, :goal,
          steps_attributes: %i[id position title description _destroy])
      end
  end
end
```

- [ ] **Step 6: The step-fields partial**

Create `app/views/rbrun/workflows/_step_fields.html.erb`:

```erb
<%# locals: index, step (a WorkflowStep or nil) %>
<div class="flex items-start gap-3 rounded-lg border border-slate-200 p-3" data-nested-fields-target="row">
  <% if step&.persisted? %>
    <input type="hidden" name="workflow[steps_attributes][<%= index %>][id]" value="<%= step.id %>">
  <% end %>
  <input type="hidden" name="workflow[steps_attributes][<%= index %>][position]" value="<%= step&.position || (index.to_i + 1) %>">
  <div class="flex-1 flex flex-col gap-2">
    <%= component("field", label: "Step title", name: "workflow[steps_attributes][#{index}][title]",
          value: step&.title, required: false, error: step&.errors&.[](:title)&.first) %>
    <%= component("textarea", label: "What to validate", rows: 2,
          name: "workflow[steps_attributes][#{index}][description]", value: step&.description) %>
  </div>
  <input type="hidden" name="workflow[steps_attributes][<%= index %>][_destroy]" value="0" data-nested-fields-target="destroy">
  <%= component("button", type: "button", variant: :ghost, size: :sm,
        data: { action: "nested-fields#remove" }) { "Remove" } %>
</div>
```

- [ ] **Step 7: The form partial + new/edit templates**

Create `app/views/rbrun/workflows/_form.html.erb`:

```erb
<%# locals: skill, workflow %>
<%= component("surface", title: workflow.persisted? ? "Edit scenario" : "New scenario", heading: :h1, inset: :centered) do |s| %>
  <% s.with_body do %>
    <%= form_with url: (workflow.persisted? ? rbrun.skill_workflow_path(skill.slug, workflow) : rbrun.skill_workflows_path(skill.slug)),
                  method: (workflow.persisted? ? :patch : :post),
                  data: { controller: "nested-fields" }, class: "flex flex-col gap-6" do %>

      <%= component("field", label: "Label", name: "workflow[label]", value: workflow.label,
            error: workflow.errors[:label].first) %>
      <%= component("field", label: "Example prompt", name: "workflow[prompt]", value: workflow.prompt,
            required: false, placeholder: "the vague request that should make the skill fire") %>
      <%= component("textarea", label: "Goal", name: "workflow[goal]", value: workflow.goal, rows: 2) %>

      <div>
        <p class="mb-2 text-sm font-semibold text-slate-800">Steps to validate</p>
        <div class="flex flex-col gap-3" data-nested-fields-target="list">
          <% workflow.steps.each_with_index do |step, i| %>
            <%= render "rbrun/workflows/step_fields", index: i, step: %>
          <% end %>
        </div>

        <template data-nested-fields-target="template">
          <%= render "rbrun/workflows/step_fields", index: "NEW_RECORD", step: nil %>
        </template>

        <%= component("button", type: "button", variant: :white, size: :sm,
              data: { action: "nested-fields#add" }, css: "mt-3") { "+ Add step" } %>
      </div>

      <div class="flex justify-end gap-2">
        <%= component("button", href: rbrun.edit_skill_path(skill.slug), variant: :ghost) { "Cancel" } %>
        <%= component("button", type: "submit", variant: :primary) { workflow.persisted? ? "Save scenario" : "Create scenario" } %>
      </div>
    <% end %>
  <% end %>
<% end %>
```

Create `app/views/rbrun/workflows/new.html.erb`:

```erb
<%= render "rbrun/workflows/form", skill: @skill, workflow: @workflow %>
```

Create `app/views/rbrun/workflows/edit.html.erb`:

```erb
<%= render "rbrun/workflows/form", skill: @skill, workflow: @workflow %>
```

- [ ] **Step 8: The Stimulus controller**

Create `app/javascript/rbrun/controllers/nested_fields_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Add/remove rows for accepts_nested_attributes_for. `add` clones the <template> (a fresh unique index
// for NEW_RECORD); `remove` deletes a new row outright, or flags a persisted one for _destroy.
export default class extends Controller {
  static targets = ["list", "template"]

  add(event) {
    event.preventDefault()
    const html = this.templateTarget.innerHTML.replace(/NEW_RECORD/g, Date.now().toString())
    this.listTarget.insertAdjacentHTML("beforeend", html)
  }

  remove(event) {
    event.preventDefault()
    const row = event.target.closest("[data-nested-fields-target='row']")
    if (!row) return
    const destroy = row.querySelector("[data-nested-fields-target='destroy']")
    if (destroy) {
      destroy.value = "1"
      row.style.display = "none"
    } else {
      row.remove()
    }
  }
}
```

Register it in `app/javascript/rbrun/rbrun.js` (import + `application.register("nested-fields", NestedFieldsController)`), matching the existing pattern.

- [ ] **Step 9: List the skill's scenarios on the skill edit form**

In `app/views/rbrun/skills/_form.html.erb`, after the "Soft hints" section and before the submit button, add a scenarios block (only when the skill is persisted):

```erb
      <% if skill %>
        <%= component("form_section", title: "Scenarios", description: "Runnable examples that self-validate this skill.") do %>
          <div class="flex flex-col gap-2">
            <% skill.workflows.order(:label).each do |wf| %>
              <div class="flex items-center justify-between rounded-lg border border-slate-200 px-3 py-2">
                <div>
                  <p class="text-sm font-medium text-slate-800"><%= wf.label %></p>
                  <p class="text-xs text-slate-500"><%= wf.steps.size %> step(s)<%= " · showcase ✓" if wf.showcase_artifact_version_id %></p>
                </div>
                <div class="flex items-center gap-2">
                  <%= button_to "▶ Run", rbrun.run_skill_workflow_path(skill.slug, wf), method: :post,
                        class: "text-xs rounded-md px-2 py-1 ring-1 ring-inset ring-slate-300 hover:bg-slate-50 cursor-pointer" %>
                  <%= link_to "Edit", rbrun.edit_skill_workflow_path(skill.slug, wf), class: "text-xs text-default-600 hover:underline" %>
                </div>
              </div>
            <% end %>
            <%= component("button", href: rbrun.new_skill_workflow_path(skill.slug), variant: :white, size: :sm, css: "self-start") do %>
              + New scenario
            <% end %>
          </div>
        <% end %>
      <% end %>
```

- [ ] **Step 10: Build assets + run the controller tests**

Run: `bun run build && bin/rails test test/controllers/rbrun/workflows_flow_test.rb`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat(scenarios): nested scenario form + ▶ Run (skill-bound workflows)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: system tests — the nested form + nested-field errors

**Files:**
- Create: `test/system/rbrun/scenario_form_test.rb`

**Interfaces:** Consumes the whole Task 4 UI in a real headless browser.

- [ ] **Step 1: Write the system test**

Create `test/system/rbrun/scenario_form_test.rb`:

```ruby
require "application_system_test_case"

module Rbrun
  class ScenarioFormTest < ApplicationSystemTestCase
    setup do
      visit "/rbrun/login"
      fill_in "email", with: "dev@rbrun.test"
      fill_in "password", with: "password"
      click_button "Sign in"
      @skill = Rbrun::Skill.create!(tenant: "rbrun", slug: "changelog", name: "Changelog")
    end

    test "authoring a scenario: add a step, submit valid, it persists" do
      visit "/rbrun/skills/changelog/workflows/new"
      fill_in "workflow[label]", with: "Weekly notes"
      fill_in "workflow[prompt]", with: "summarize the week"

      # one row exists; fill it
      first("input[name^='workflow[steps_attributes]'][name$='[title]']").set("Collect PRs")
      first("textarea[name^='workflow[steps_attributes]'][name$='[description]']").set("gather merged PRs")

      # add a second row via the Stimulus controller and fill it
      click_button "+ Add step"
      titles = all("input[name^='workflow[steps_attributes]'][name$='[title]']")
      assert_equal 2, titles.size
      titles.last.set("Group by type")

      click_button "Create scenario"

      assert_current_path "/rbrun/skills/changelog/edit"
      wf = @skill.workflows.find_by(label: "Weekly notes")
      assert wf
      assert_equal %w[Collect\ PRs Group\ by\ type], wf.steps.order(:position).pluck(:title)
    end

    test "a nested step with a description but no title surfaces a field error and preserves input" do
      visit "/rbrun/skills/changelog/workflows/new"
      fill_in "workflow[label]", with: "Bad step"
      # leave step title blank, give it a description → not all-blank → invalid
      first("textarea[name^='workflow[steps_attributes]'][name$='[description]']").set("content but no title")

      click_button "Create scenario"

      # server re-renders unprocessable_entity with the nested error + the entered value preserved
      assert_text "can't be blank"
      assert_selector "textarea[name$='[description]']" do |_|
        # the description the user typed survived the round-trip
      end
      assert_equal "content but no title",
                   first("textarea[name^='workflow[steps_attributes]'][name$='[description]']").value
      assert_equal 0, @skill.workflows.count
    end

    test "removing a new row drops it before submit" do
      visit "/rbrun/skills/changelog/workflows/new"
      fill_in "workflow[label]", with: "One step only"
      first("input[name$='[title]']").set("Keep me")
      click_button "+ Add step"
      assert_equal 2, all("input[name$='[title]']").size
      all("button", text: "Remove").last.click
      # the removed NEW row is gone from the DOM
      assert_equal 1, all("input[name$='[title]']").size
      click_button "Create scenario"
      assert_equal 1, @skill.workflows.find_by(label: "One step only").steps.count
    end
  end
end
```

- [ ] **Step 2: Run the system tests**

Run: `bin/rails test:system test/system/rbrun/scenario_form_test.rb`
Expected: PASS (headless Chrome; assets already built in Task 4). If the field-error text differs, adjust the assertion to the actual message rendered by the `field`/`textarea` primitive's `error:` slot (title error shows on the title `field`).

Note: the title error must render — the `_step_fields` partial passes `error: step&.errors&.[](:title)&.first` to the title `field`. On the invalid re-render the built step carries the error, so it shows. If the primitive renders the error only when `error:` is present (it does), this works.

- [ ] **Step 3: Commit**

```bash
git add test/system/rbrun/scenario_form_test.rb
git commit -m "test(scenarios): system tests — nested step form + nested-field error handling

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: run the dogfood — prove the whole loop clean

**Files:** none (execution + verification).

- [ ] **Step 1: Full suite + lint green first**

Run: `bin/rails test && bin/rubocop -a`
Expected: all green; rubocop clean.

- [ ] **Step 2: Run the scenarios dogfood (real Claude + Daytona)**

Run: `bin/rails app:dogfood:scenarios`
Expected: the `create-skill · Builds and promotes a small skill` scenario replays, both steps self-validate (`✓ Author the skill folder`, `✓ Promote the skill`), a showcase artifact is captured (`showcase: artifact #… v1`), and the tail prints `— 1/1 scenarios passed`. No box/worktree left behind (reaped in `ensure`).

- [ ] **Step 3: If a step fails, diagnose (do not paper over)**

If the run is not green, read the printed evidence + the run's session messages. Common causes: the workflow's `prompt` didn't make the skill fire (fix the scenario prompt/steps), or provisioning/toolchain (Plan-1-era fixes). Fix the real cause, re-run until `— 1/1 scenarios passed`.

- [ ] **Step 4: Final branch state**

Report the green dogfood output. The branch now delivers Plan 1 + Plan 2 — the full author → run → validate → showcase loop.

## Self-Review (against the spec)

- **Coverage:** `workflows.skill_id/prompt/showcase_artifact_version_id` + `Skill has_many :workflows` (T1); `SkillScenarioRun` binds a skill-bound workflow, replays `prompt`, captures showcase (T2); `SkillScenario` retired, ingest → workflows, dogfood board over `Workflow.scenarios` (T3); nested `resources :workflows` form + ▶ Run (T4); **system tests emphasizing nested-field error handling** (T5, per the explicit ask); the dogfood proves it end-to-end (T6).
- **Invariants:** Workflow stays general (nullable scenario columns; conversation workflows untouched); the template workflow is never destroyed by a run; ingest is idempotent; no raw HTML controls (primitives only); self-validating runs tagged `:skill_scenario` + filtered from the conversation index (Plan 1).
- **Placeholders:** none — every step has real code. The one flexible spot is the exact nested-error wording asserted in T5 Step 2 (adjust to the primitive's rendered message).
