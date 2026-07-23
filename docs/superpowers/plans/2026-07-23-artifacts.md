# Artifacts (Plan C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the agent a `save_artifact` tool that persists a single workspace file as a first-class, versioned, addressable deliverable in rbrun's DB.

**Architecture:** Two engine models — `Rbrun::Artifact` (identity + history, no ownership) and `Rbrun::ArtifactVersion` (immutable snapshot, one ActiveStorage blob, stamped with the turn's lead message for provenance). A thin ungated tool reads the workspace file and calls one model method that find-or-creates the artifact, appends a numbered version, attaches the blob, and advances `current_version`. Context (session/worktree) is always *derived* via `version.message.session` — never stored on the artifact.

**Tech Stack:** Rails 8.1 engine, ActiveStorage (`has_one_attached`), RubyLLM tool base (`Rbrun::ApplicationTool`), Minitest.

## Global Constraints

- Ruby 3.4.4, Rails `>= 8.1.3`. Engine — `bin/rails` runs against `test/dummy`; engine rake tasks are namespaced under `app:`.
- Test suite: `bin/rails test`. Single file: `bin/rails test <path>`. CI equivalent: `bin/rails db:test:prepare test`. Lint: `bin/rubocop -a`.
- Every engine record carries a required tenant column named `Rbrun.config.tenancy_key` (default `"tenant"`, default slug `"rbrun"`); migrations write the column via `Rbrun.config.tenancy_key`, models `include Rbrun::Tenanted`.
- Engine models inherit `Rbrun::ApplicationRecord`. Tools inherit `Rbrun::ApplicationTool`, live in `app/tools/rbrun/tools/`, are registered in `lib/rbrun/engine.rb` via `Rbrun.register_tool`, and return string-keyed `{ "data" => {…} }` on success or `error("msg")` on a recoverable failure.
- **An artifact has no ownership** — no `belongs_to :session`, no user. Provenance lives on `ArtifactVersion.belongs_to :message`. Tenant is scope only.
- **Single file per artifact** — `save_artifact` takes one `path:`, `has_one_attached :file`. No multi-file, no `kind` column, no `content` column (content-type is read off the blob).
- **Ungated** — `save_artifact` does NOT declare `needs_approval!`.

---

### Task 1: Artifact models + migrations

**Files:**
- Create: `db/migrate/20260723120000_create_rbrun_artifacts.rb`
- Create: `db/migrate/20260723120001_create_rbrun_artifact_versions.rb`
- Create: `app/models/rbrun/artifact.rb`
- Create: `app/models/rbrun/artifact_version.rb`
- Test: `test/models/rbrun/artifact_test.rb`

**Interfaces:**
- Produces:
  - `Rbrun::Artifact` — `Tenanted`; `has_many :versions` (class `Rbrun::ArtifactVersion`); `belongs_to :current_version` (optional); `name:string`.
  - `Rbrun::ArtifactVersion` — `belongs_to :artifact`; `belongs_to :message` (class `Rbrun::SessionMessage`); `has_one_attached :file`; `number:integer`.
  - `Rbrun::Artifact.append_version!(tenant:, message:, io:, filename:, name: nil, artifact_id: nil) -> Rbrun::ArtifactVersion` — find-or-create the artifact (scoped `for_tenant(tenant)` when `artifact_id` given, else create with `name || filename`), create the next-numbered version stamped with `message`, attach `io`/`filename` as `file`, set `current_version`, return the version. Raises `ActiveRecord::RecordNotFound` if `artifact_id` is not this tenant's.

- [ ] **Step 1: Write the migrations**

Create `db/migrate/20260723120000_create_rbrun_artifacts.rb`:

```ruby
class CreateRbrunArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_artifacts do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :name, null: false
      t.bigint :current_version_id            # → rbrun_artifact_versions (set after the version exists)
      t.timestamps
    end
    add_index :rbrun_artifacts, Rbrun.config.tenancy_key
  end
end
```

Create `db/migrate/20260723120001_create_rbrun_artifact_versions.rb`:

```ruby
class CreateRbrunArtifactVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_artifact_versions do |t|
      t.references :artifact, null: false, foreign_key: { to_table: :rbrun_artifacts }
      t.references :message,  null: false, foreign_key: { to_table: :rbrun_session_messages }
      t.integer :number, null: false          # 1-based, per artifact
      t.timestamps
    end
    add_index :rbrun_artifact_versions, %i[artifact_id number], unique: true
  end
end
```

- [ ] **Step 2: Apply the migrations**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: both migrations run; `test/dummy/db/schema.rb` now contains `create_table "rbrun_artifacts"` and `create_table "rbrun_artifact_versions"`.

- [ ] **Step 3: Write the models**

Create `app/models/rbrun/artifact.rb`:

```ruby
module Rbrun
  # A first-class, versioned deliverable the agent produced (a report, a document). NO OWNERSHIP:
  # provenance lives on each version's `message`; session/worktree/context are always DERIVED via
  # `version.message.session`, never stored here. Tenant is scope only (invariant #8).
  class Artifact < ApplicationRecord
    include Rbrun::Tenanted

    has_many :versions, class_name: "Rbrun::ArtifactVersion", dependent: :destroy
    belongs_to :current_version, class_name: "Rbrun::ArtifactVersion", optional: true

    validates :name, presence: true

    # Persist one workspace file as the artifact's next version. Find-or-create the artifact (scoped to
    # the tenant when re-versioning an existing one), append a numbered immutable version stamped with
    # the producing turn's `message`, attach the blob, and advance `current_version`. Each call is a NEW
    # version; history is never mutated. The tenant column is configurable, so it is set by name
    # (`Rbrun.config.tenancy_key`) rather than assuming a literal `tenant:` attribute.
    def self.append_version!(tenant:, message:, io:, filename:, name: nil, artifact_id: nil)
      transaction do
        artifact =
          if artifact_id
            for_tenant(tenant).find(artifact_id)
          else
            create!(Rbrun.config.tenancy_key => tenant, :name => name.presence || filename)
          end
        number  = artifact.versions.maximum(:number).to_i + 1
        version = artifact.versions.create!(number: number, message: message)
        version.file.attach(io: io, filename: filename)
        artifact.update!(current_version: version)
        version
      end
    end
  end
end
```

Create `app/models/rbrun/artifact_version.rb`:

```ruby
module Rbrun
  # An immutable snapshot of an Artifact: one ActiveStorage blob (`file`), a per-artifact `number`, and
  # the `message` (the turn's lead user message) that produced it — the artifact's ONLY provenance link.
  # `content_type`/`byte_size` are read off the blob; there is no `kind` column.
  class ArtifactVersion < ApplicationRecord
    belongs_to :artifact, class_name: "Rbrun::Artifact"
    belongs_to :message,  class_name: "Rbrun::SessionMessage"

    has_one_attached :file

    validates :number, presence: true, uniqueness: { scope: :artifact_id }

    delegate :content_type, :byte_size, to: :file, allow_nil: true
  end
end
```

- [ ] **Step 4: Write the failing model test**

Create `test/models/rbrun/artifact_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class ArtifactTest < ActiveSupport::TestCase
    setup do
      @session = rbrun_session(tenant: "acme")
      @message = @session.messages.create!(role: "user", event_type: "text", content: "make a report")
    end

    test "append_version! creates a new artifact, version 1, attaches the blob, sets current_version" do
      version = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("hello"), filename: "notes.txt"
      )

      artifact = version.artifact
      assert_equal "acme", artifact.tenant
      assert_equal "notes.txt", artifact.name
      assert_equal 1, version.number
      assert_equal artifact.current_version, version
      assert version.file.attached?
      assert_equal "text/plain", version.content_type
      assert_equal 5, version.byte_size
      assert_equal @message, version.message
    end

    test "append_version! with artifact_id appends version 2 and advances current_version" do
      v1 = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("a"), filename: "notes.txt"
      )
      v2 = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("bb"), filename: "notes.txt",
        artifact_id: v1.artifact_id
      )

      assert_equal v1.artifact_id, v2.artifact_id
      assert_equal 2, v2.number
      assert_equal v2, v1.artifact.reload.current_version
      assert_equal 2, v1.artifact.versions.count
    end

    test "append_version! with an explicit name uses it over the basename" do
      version = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("x"), filename: "notes.txt", name: "Quarterly report"
      )
      assert_equal "Quarterly report", version.artifact.name
    end

    test "append_version! rejects another tenant's artifact_id" do
      other = Rbrun::Artifact.append_version!(
        tenant: "other", message: @message, io: StringIO.new("x"), filename: "notes.txt"
      )
      assert_raises(ActiveRecord::RecordNotFound) do
        Rbrun::Artifact.append_version!(
          tenant: "acme", message: @message, io: StringIO.new("y"), filename: "notes.txt",
          artifact_id: other.artifact_id
        )
      end
    end
  end
end
```

- [ ] **Step 5: Run the model test**

Run: `bin/rails test test/models/rbrun/artifact_test.rb`
Expected: PASS (4 tests). If `content_type` is `nil`, ActiveStorage identification is off — confirm the blob was attached with a filename (it is) and that `test/dummy/config/environments/test.rb` sets `config.active_storage.service = :test` (it does).

- [ ] **Step 6: Lint + commit**

```bash
bin/rubocop -a app/models/rbrun/artifact.rb app/models/rbrun/artifact_version.rb
git add db/migrate/20260723120000_create_rbrun_artifacts.rb db/migrate/20260723120001_create_rbrun_artifact_versions.rb app/models/rbrun/artifact.rb app/models/rbrun/artifact_version.rb test/models/rbrun/artifact_test.rb test/dummy/db/schema.rb
git commit -m "feat(artifacts): Artifact + ArtifactVersion models with append_version!"
```

---

### Task 2: `save_artifact` tool

**Files:**
- Create: `app/tools/rbrun/tools/save_artifact.rb`
- Modify: `lib/rbrun/engine.rb` (register the tool)
- Test: `test/tools/rbrun/save_artifact_test.rb`

**Interfaces:**
- Consumes: `Rbrun::Artifact.append_version!` (Task 1); `session.sandbox.read(path)`, `session.open_turn_lead`, `session.tenant` (existing).
- Produces: `Rbrun::Tools::SaveArtifact` (tool name demodulizes to `"save_artifact"`), returning
  `{ "data" => { "artifact_id" => Integer, "name" => String, "version" => Integer, "content_type" => String, "byte_size" => Integer } }`
  or `error("…")`.

- [ ] **Step 1: Write the tool**

Create `app/tools/rbrun/tools/save_artifact.rb`:

```ruby
require "stringio"

module Rbrun
  module Tools
    # Save a SINGLE workspace file as a versioned artifact — a first-class deliverable (a report, a
    # document) that outlives the turn. Ungated: producing a deliverable is leaf output, not a state
    # mutation. The bytes travel via the workspace file, never through the tool-call payload.
    class SaveArtifact < Rbrun::ApplicationTool
      description <<~TXT
        Save a single file from your workspace as a versioned artifact — a first-class deliverable such
        as a report or document. Write the file first, then call this with its workspace-relative `path`.
        Omit `artifact_id` to create a new artifact; pass it to add a new version to an existing one.
      TXT

      parameter :path, type: "string", required: true,
                description: %(workspace-relative path to the file to save, e.g. "report.md")
      parameter :name, type: "string", required: false,
                description: "human name for the artifact (defaults to the file's basename)"
      parameter :artifact_id, type: "integer", required: false,
                description: "existing artifact id to add a new version to; omit to create a new one"

      def execute(path:, name: nil, artifact_id: nil)
        message = session.open_turn_lead
        return error("no active turn to attribute this artifact to") unless message

        bytes   = session.sandbox.read(path)
        version = Rbrun::Artifact.append_version!(
          tenant: tenant, message: message, io: StringIO.new(bytes),
          filename: File.basename(path), name: name, artifact_id: artifact_id
        )
        { "data" => { "artifact_id" => version.artifact_id, "name" => version.artifact.name,
                      "version" => version.number, "content_type" => version.content_type,
                      "byte_size" => version.byte_size } }
      rescue ActiveRecord::RecordNotFound
        error("artifact ##{artifact_id} not found for this tenant")
      end
    end
  end
end
```

- [ ] **Step 2: Register the tool**

Modify `lib/rbrun/engine.rb`. Find the block that calls `Rbrun.register_tool` for the workflow tools:

```ruby
      [ Rbrun::Tools::WorkflowCreate, Rbrun::Tools::ValidateStep, Rbrun::Tools::CancelWorkflow,
        Rbrun::Tools::WorkflowSearch, Rbrun::Tools::UseWorkflow ].each { |t| Rbrun.register_tool(t) }
```

Add immediately after it:

```ruby
      Rbrun.register_tool(Rbrun::Tools::SaveArtifact)
```

- [ ] **Step 3: Write the failing tool test**

Create `test/tools/rbrun/save_artifact_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class SaveArtifactTest < ActiveSupport::TestCase
    # Serves file bytes instead of touching a real box.
    class FakeSandbox
      def initialize(files) = @files = files
      def workspace = "/ws"
      def read(path) = @files.fetch(path)
    end

    setup do
      @session = rbrun_session(tenant: "acme")
      @session.messages.create!(role: "user", event_type: "text", content: "make a report")
      @sandbox = FakeSandbox.new("report.md" => "# Title\nbody\n")
      @session.worktree.instance_variable_set(:@sandbox, @sandbox)
    end

    test "the tool name demodulizes to save_artifact" do
      assert_equal "save_artifact", Rbrun::Tools::SaveArtifact.new(tenant: "acme").name
    end

    test "the tool is ungated" do
      refute Rbrun::Tools::SaveArtifact.needs_approval?
    end

    test "executing reads the workspace file and creates a versioned artifact" do
      result = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md")

      data = result.fetch("data")
      assert_equal 1, data["version"]
      assert_equal "report.md", data["name"]
      assert_operator data["byte_size"], :>, 0

      artifact = Rbrun::Artifact.for_tenant("acme").find(data["artifact_id"])
      assert artifact.current_version.file.attached?
      assert_equal "# Title\nbody\n", artifact.current_version.file.download
    end

    test "passing artifact_id appends a second version" do
      first  = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md")
      id     = first.dig("data", "artifact_id")
      second = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md", artifact_id: id)

      assert_equal 2, second.dig("data", "version")
      assert_equal id, second.dig("data", "artifact_id")
    end

    test "an unknown artifact_id returns a recoverable error" do
      result = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md", artifact_id: 999_999)
      assert_match(/not found/, result["error"])
    end
  end
end
```

- [ ] **Step 4: Run the tool test**

Run: `bin/rails test test/tools/rbrun/save_artifact_test.rb`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full suite (registration must not break the manifest/boot)**

Run: `bin/rails test`
Expected: PASS. The new tool now appears in `Rbrun::ApplicationTool.manifest`; no approval card is required because it is ungated.

- [ ] **Step 6: Lint + commit**

```bash
bin/rubocop -a app/tools/rbrun/tools/save_artifact.rb lib/rbrun/engine.rb
git add app/tools/rbrun/tools/save_artifact.rb lib/rbrun/engine.rb test/tools/rbrun/save_artifact_test.rb
git commit -m "feat(artifacts): save_artifact tool — persist a workspace file as a versioned artifact"
```

---

### Task 3: Artifacts dogfood (acceptance gate)

**Files:**
- Create: `lib/tasks/rbrun/dogfood/artifacts.rake`

**Interfaces:**
- Consumes: `Rbrun::Dogfood` support (`load_env!`, `header`, `ok`, `info`), `Rbrun::Tools::SaveArtifact` (via a real turn), `Rbrun::Artifact` (Tasks 1–2).

This drives ONE real turn (real Claude + real Daytona) that writes a file and calls `save_artifact`, then asserts a versioned artifact with an attached blob exists for the tenant. It **reaps prior dogfood artifacts at start** and **destroys its box + records in `ensure`** (idempotency #11).

- [ ] **Step 1: Write the dogfood task**

Create `lib/tasks/rbrun/dogfood/artifacts.rake`:

```ruby
# frozen_string_literal: true

require_relative "support"

# Artifacts dogfood — a REAL turn writes a file and calls save_artifact; a versioned artifact with an
# attached blob lands in the DB, scoped to the tenant, with provenance on the turn's lead message.
# Real Claude + real Daytona; no GitHub. Creds from .env (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY).
#
#   bin/rails app:dogfood:artifacts
namespace :dogfood do
  desc "Artifacts: a real turn writes a file and save_artifact persists it as a versioned artifact"
  task artifacts: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end

    dog.header "reap prior dogfood artifacts (idempotency)"
    Rbrun::Artifact.for_tenant("dogfood").destroy_all
    dog.ok "no dogfood artifacts remain", Rbrun::Artifact.for_tenant("dogfood").none?

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: "rbdotrun/scratch")
    session = wt.sessions.create!(tenant: "dogfood")
    begin
      dog.header "a real turn writes a file and calls save_artifact"
      session.run_turn(
        "Write a short markdown file called report.md containing a one-line status, " \
        "then save it as an artifact using the save_artifact tool."
      )
      dog.ok "status landed on done", session.reload.done?

      tool_uses = session.messages.where(event_type: "tool_use")
      dog.info "tool_use events", tool_uses.map { |m| m.payload["name"] }.inspect
      dog.ok "save_artifact was called", tool_uses.any? { |m| m.payload["name"].to_s == "save_artifact" }

      artifact = Rbrun::Artifact.for_tenant("dogfood").order(:id).last
      dog.ok "an artifact was persisted for the tenant", artifact.present?
      dog.ok "it has a current version with an attached blob",
             artifact&.current_version&.file&.attached? == true
      dog.ok "provenance points at this session's turn",
             artifact&.current_version&.message&.session_id == session.id
      dog.info "content_type", artifact&.current_version&.content_type
    ensure
      session.sandbox.destroy!
      wt.destroy!
      Rbrun::Artifact.for_tenant("dogfood").destroy_all
    end
  end
end
```

- [ ] **Step 2: Run the dogfood (requires .env creds)**

Run: `bin/rails app:dogfood:artifacts`
Expected: all `✓` lines green — the turn reaches `done`, `save_artifact` appears in the tool_use log, and a tenant-scoped artifact with an attached blob and message-derived provenance exists. If creds are absent the task aborts cleanly (that is acceptable in an offline environment; note it and move on).

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/rbrun/dogfood/artifacts.rake
git commit -m "test(dogfood): artifacts — a real turn persists a versioned artifact via save_artifact"
```

---

## Self-Review

**Spec coverage (Plan C section of `2026-07-23-artifacts-skills-and-eval-design.md`):**
- `Rbrun::Artifact` (Tenanted, name, versions, current_version, no session/user/kind/content) → Task 1 ✓
- `Rbrun::ArtifactVersion` (belongs_to artifact + message, has_one_attached :file, number) → Task 1 ✓
- Provenance via `message`, context derived via `message.session` → Task 1 model + Task 3 assertion ✓
- `save_artifact(path:, name:, artifact_id:)` reads one workspace file, ungated, returns the documented data → Task 2 ✓
- `artifact_id` omitted → new; present → new version, current advances → Tasks 1 & 2 ✓
- Storage durability (ActiveStorage service) → uses the dummy's configured `:test`/`:local` service; single-DB, schema already carries `active_storage_*` tables → Task 1 Step 5 note ✓
- Testing (C): model + tool tests, dogfood reaping at start and destroying at end → Tasks 1–3 ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. (Task 1 Step 3 deliberately walks the `create!` attribute-key fix inline and ends with the final method body — not a placeholder.)

**Type consistency:** `append_version!(tenant:, message:, io:, filename:, name:, artifact_id:)` is defined in Task 1 and consumed with the identical keywords in Task 2. The tool's returned `data` keys (`artifact_id`, `name`, `version`, `content_type`, `byte_size`) match between Task 2's implementation and its test. `session.open_turn_lead`, `session.sandbox.read`, `Rbrun.register_tool`, and `for_tenant` all match verified codebase signatures.
