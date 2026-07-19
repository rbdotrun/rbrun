# Phase 4 — Engine host: persistence + config spine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the engine its persistence + config spine: the `Rbrun.configure` aggregator with the `Rbrun.sandbox`/`Rbrun.runtime` config-aware constructors, the `connects_to` DB toggle, the `Session`/`SessionMessage` event-log models, always-on configurable tenancy, and an install generator — a mounted, migrated engine that stores a conversation's event log. **No turn loop yet** (Phase 5).

**Architecture:** Engine models inherit `Rbrun::ApplicationRecord`, which `connects_to` a separate DB when `Rbrun.config.database_connection` isn't `:primary`. `Rbrun::Tenanted` adds a required, configurably-named tenant slug column + a `for_tenant` scope. `Session` (status enum, `sdk_session_id`, `#sandbox` via `Rbrun.sandbox`) `has_many` `SessionMessage` rows — one per event, `payload` json, approval columns. `Rbrun.sandbox`/`Rbrun.runtime` are thin wrappers over Phase 1's `Rbrun.build`, reading `Rbrun.config` and handing the pure gems an explicit config hash.

**Tech Stack:** Rails engine (`>= 8.1.3`), ActiveRecord, Minitest via `bin/rails test`. Depends on `rbrun-sandbox` + `rbrun-runtime`.

## Global Constraints

- **Config-aware constructors read config; gems stay pure.** `Rbrun.sandbox`/`Rbrun.runtime` = `Rbrun.build(<family>, Rbrun.config.<family>_provider, provider:, **opts)`. The pure gems never read global state.
- **Tenancy is always on, name configurable.** Every engine record includes `Rbrun::Tenanted` → a `<Rbrun.config.tenancy_key>` slug column (`NOT NULL`, indexed; default name `"tenant"`, default value `"rbrun"`) + `for_tenant(slug)`.
- **Own DB via `connects_to`.** `Rbrun::ApplicationRecord` connects to `Rbrun.config.database_connection` unless it's `:primary`. `database_connection` must be set (host initializer) before models load.
- **`SessionMessage` is a raw event log** — one row per event: `role`, `event_type`, `payload` (json), `content`, `tool_use_id`, `approval_status`. No interpretation here (Phase 5/7). No Turbo (Phase 7).
- **Naming:** `Session`/`SessionMessage` (the conversation aggregate) — distinct from the sandbox process session and `sdk_session_id`.
- **Dogfood:** `lib/tasks/rbrun/dogfood/session_log.rake`, one scenario, never variabilized.
- **Ruby 3.4.4.**

---

## File Structure

**Created:**
- `app/models/concerns/rbrun/tenanted.rb`
- `app/models/rbrun/session.rb`, `app/models/rbrun/session_message.rb`
- `db/migrate/<ts>_create_rbrun_sessions.rb`, `db/migrate/<ts>_create_rbrun_session_messages.rb`
- `lib/generators/rbrun/install/install_generator.rb` + `lib/generators/rbrun/install/templates/rbrun.rb`
- `test/dummy/config/initializers/rbrun.rb`
- `lib/tasks/rbrun/dogfood/session_log.rake`
- Tests: `test/rbrun/constructors_test.rb`, `test/rbrun/tenanted_test.rb`, `test/models/rbrun/session_test.rb`, `test/models/rbrun/session_message_test.rb`

**Modified:**
- `lib/rbrun.rb` — `Rbrun.sandbox`/`Rbrun.runtime` constructors; require the gems.
- `app/models/rbrun/application_record.rb` — `connects_to` toggle.
- `rbrun.gemspec` — depend on `rbrun-sandbox`, `rbrun-runtime`.

---

### Task 1: Config-aware constructors — `Rbrun.sandbox` / `Rbrun.runtime`

**Files:**
- Modify: `lib/rbrun.rb`, `rbrun.gemspec`
- Test: `test/rbrun/constructors_test.rb`

**Interfaces:**
- Produces: `Rbrun.sandbox(provider = nil, **opts) -> <sandbox adapter>` and `Rbrun.runtime(sandbox:, provider: nil, **opts) -> <runtime adapter>`, both over `Rbrun.build` reading `Rbrun.config`.

- [ ] **Step 1: depend on the sub-gems**

In `rbrun.gemspec`, add below the rails dependency:

```ruby
  spec.add_dependency "rbrun-sandbox"
  spec.add_dependency "rbrun-runtime"
```

- [ ] **Step 2: write the failing test**

`test/rbrun/constructors_test.rb`:

```ruby
require "test_helper"

class ConstructorsTest < ActiveSupport::TestCase
  setup { Rbrun.reset_config! }
  teardown { Rbrun.reset_config! }

  test "Rbrun.sandbox resolves the default provider from config" do
    Rbrun.configure { |c| c.sandbox_provider = { default: :local, local: {} } }
    box = Rbrun.sandbox(labels: { session: "ctor" })
    assert_instance_of Rbrun::Sandbox::Local, box
  ensure
    box&.destroy!
  end

  test "Rbrun.sandbox honors an explicit provider override" do
    Rbrun.configure { |c| c.sandbox_provider = { default: :local, local: {} } }
    box = Rbrun.sandbox(:local, labels: { session: "ctor2" })
    assert_instance_of Rbrun::Sandbox::Local, box
  ensure
    box&.destroy!
  end

  test "Rbrun.runtime resolves claude_sdk with an injected sandbox" do
    Rbrun.configure do |c|
      c.sandbox_provider = { default: :local, local: {} }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: "sk-test" } }
    end
    box = Rbrun.sandbox(labels: { session: "ctor3" })
    rt = Rbrun.runtime(sandbox: box)
    assert_instance_of Rbrun::Runtime::ClaudeSdk, rt
  ensure
    box&.destroy!
  end
end
```

- [ ] **Step 3: run — verify it fails**

Run: `bin/rails test test/rbrun/constructors_test.rb`
Expected: FAIL (`NoMethodError: undefined method 'sandbox' for Rbrun`).

- [ ] **Step 4: add the constructors**

In `lib/rbrun.rb`, add inside `module Rbrun` (after the requires):

```ruby
require "rbrun/version"
require "rbrun/config"
require "rbrun/resolver"
require "rbrun/engine"

module Rbrun
  # Config-aware constructors: read Rbrun.config and hand the pure gems an explicit config hash via
  # Rbrun.build. The gems themselves never read global state.
  class << self
    def sandbox(provider = nil, **opts)
      require "rbrun/sandbox"
      build(Rbrun::Sandbox, config.sandbox_provider, provider: provider, **opts)
    end

    def runtime(sandbox:, provider: nil, **opts)
      require "rbrun/runtime"
      build(Rbrun::Runtime, config.runtime_provider, provider: provider, sandbox: sandbox, **opts)
    end
  end
end
```

- [ ] **Step 5: run — verify it passes**

Run: `bin/rails test test/rbrun/constructors_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 6: commit**

```bash
git add lib/rbrun.rb rbrun.gemspec test/rbrun/constructors_test.rb Gemfile.lock
git commit -m "feat(engine): Rbrun.sandbox/Rbrun.runtime config-aware constructors"
```

---

### Task 2: DB toggle + `Rbrun::Tenanted`

**Files:**
- Modify: `app/models/rbrun/application_record.rb`
- Create: `app/models/concerns/rbrun/tenanted.rb`
- Test: `test/rbrun/tenanted_test.rb`

**Interfaces:**
- Produces: `Rbrun::ApplicationRecord` (abstract; `connects_to` when `database_connection != :primary`); `Rbrun::Tenanted` — `for_tenant(slug)` scope + `#tenant` reader, both keyed on `Rbrun.config.tenancy_key`.

- [ ] **Step 1: the DB toggle**

Replace `app/models/rbrun/application_record.rb`:

```ruby
module Rbrun
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # Own DB by default; :primary keeps everything in the host's primary connection (the escape
    # hatch). Set via Rbrun.config.database_connection in the host initializer, before models load.
    conn = Rbrun.config.database_connection
    connects_to database: { writing: conn, reading: conn } if conn && conn != :primary
  end
end
```

- [ ] **Step 2: write the failing test**

`test/rbrun/tenanted_test.rb`:

```ruby
require "test_helper"

class TenantedTest < ActiveSupport::TestCase
  test "for_tenant scopes on the configured tenancy_key column" do
    # Rbrun::Session includes Tenanted; the dummy configures tenancy_key = "tenant".
    a = Rbrun::Session.create!(tenant: "acme")
    b = Rbrun::Session.create!(tenant: "globex")
    assert_includes Rbrun::Session.for_tenant("acme"), a
    refute_includes Rbrun::Session.for_tenant("acme"), b
    assert_equal "acme", a.tenant
  end
end
```

- [ ] **Step 3: run — verify it fails**

Run: `bin/rails test test/rbrun/tenanted_test.rb`
Expected: FAIL (`Rbrun::Session` / `Rbrun::Tenanted` not defined yet). It goes green once Task 3 lands the model + migration; run it again there.

- [ ] **Step 4: the concern**

`app/models/concerns/rbrun/tenanted.rb`:

```ruby
module Rbrun
  # Roots every engine record to a tenant slug. MANDATORY: the column is NOT NULL. Its NAME is
  # configurable (Rbrun.config.tenancy_key, default "tenant"); the default slug value is "rbrun".
  module Tenanted
    extend ActiveSupport::Concern

    included do
      scope :for_tenant, ->(slug) { where(Rbrun.config.tenancy_key => slug) }
    end

    def tenant = self[Rbrun.config.tenancy_key]
  end
end
```

- [ ] **Step 5: commit** (after Task 3 makes the test green)

```bash
git add app/models/rbrun/application_record.rb app/models/concerns/rbrun/tenanted.rb test/rbrun/tenanted_test.rb
git commit -m "feat(engine): connects_to DB toggle + Rbrun::Tenanted (configurable slug)"
```

---

### Task 3: `Session` + `SessionMessage` models + migrations

**Files:**
- Create: `db/migrate/<ts>_create_rbrun_sessions.rb`, `db/migrate/<ts>_create_rbrun_session_messages.rb`, `app/models/rbrun/session.rb`, `app/models/rbrun/session_message.rb`
- Create: `test/dummy/config/initializers/rbrun.rb` (config for the dummy — needed to boot models)
- Test: `test/models/rbrun/session_test.rb`, `test/models/rbrun/session_message_test.rb`

**Interfaces:**
- Produces: `Rbrun::Session` (`status` enum idle/working/needs_approval/done/failed, `sdk_session_id`, `#sandbox`, `has_many :messages`, `Tenanted`); `Rbrun::SessionMessage` (`belongs_to :session`, `approval_status` enum with `:approval` prefix, `scope :gated`, self-referential `user_message`).

- [ ] **Step 1: the dummy config initializer** (so the engine + models boot in `test/dummy`)

`test/dummy/config/initializers/rbrun.rb`:

```ruby
Rbrun.configure do |c|
  c.database_connection = :primary      # dummy uses one sqlite DB; no separate connection
  c.tenancy_key         = "tenant"
  c.sandbox_provider    = { default: :local, local: {} }
  c.runtime_provider    = { default: :claude_sdk, claude_sdk: { anthropic_api_key: "sk-test-dummy" } }
  c.user email: "dev@rbrun.test", password: "password", tenant: "rbrun"
end
```

- [ ] **Step 2: migrations**

`db/migrate/<ts>_create_rbrun_sessions.rb` (use a real timestamp, e.g. `20260719120000`):

```ruby
class CreateRbrunSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_sessions do |t|
      t.string   Rbrun.config.tenancy_key, null: false   # the configurable tenant slug
      t.string   :status, null: false, default: "idle"
      t.string   :sdk_session_id
      t.datetime :archived_at
      t.timestamps
    end
    add_index :rbrun_sessions, Rbrun.config.tenancy_key
  end
end
```

`db/migrate/<ts+1>_create_rbrun_session_messages.rb`:

```ruby
class CreateRbrunSessionMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_session_messages do |t|
      t.references :session, null: false, foreign_key: { to_table: :rbrun_sessions }
      t.string  :role
      t.string  :event_type
      t.text    :content
      t.json    :payload, null: false, default: {}
      t.string  :tool_use_id
      t.string  :approval_status
      t.bigint  :user_message_id
      t.timestamps
    end
    add_index :rbrun_session_messages, :event_type
    add_index :rbrun_session_messages, :tool_use_id
    add_index :rbrun_session_messages, %i[session_id approval_status], where: "approval_status IS NOT NULL",
              name: "idx_rbrun_msgs_pending"
  end
end
```

- [ ] **Step 3: apply migrations to the dummy (dev + test DBs)**

Run:
```bash
bin/rails app:db:migrate       # dummy dev DB (engine migrations are on the dummy's path via test_helper/engine)
RAILS_ENV=test bin/rails app:db:migrate
```
If `app:db:migrate` doesn't see the engine migrations, install them first: `bin/rails app:rbrun:install:migrations` (mountable engines expose `<engine>:install:migrations`), then re-run migrate.
Expected: `rbrun_sessions` + `rbrun_session_messages` created.

- [ ] **Step 4: the models**

`app/models/rbrun/session.rb`:

```ruby
module Rbrun
  # ONE conversation: an event log + the sandbox it works in, rooted to a tenant. The turn loop
  # (#run_turn) arrives in Phase 5; here a Session persists and resolves its sandbox.
  class Session < ApplicationRecord
    include Rbrun::Tenanted

    has_many :messages, -> { order(:created_at, :id) },
             class_name: "Rbrun::SessionMessage", dependent: :destroy

    enum :status,
         { idle: "idle", working: "working", needs_approval: "needs_approval", done: "done", failed: "failed" },
         default: "idle"

    # The conversation's box, addressed by label (see Rbrun::Sandbox). Memoized per instance.
    def sandbox = @sandbox ||= Rbrun.sandbox(labels: { session: id.to_s })
  end
end
```

`app/models/rbrun/session_message.rb`:

```ruby
module Rbrun
  # ONE row per runtime event — a raw event log (no tool_calls/tool_results tables). `event_type` is
  # the event's type (text/tool_use/tool_result/token/session/…); `payload` its raw JSON. Ingested
  # verbatim; interpretation happens at render time (Phase 7).
  class SessionMessage < ApplicationRecord
    belongs_to :session, class_name: "Rbrun::Session"

    # The user message that opened this row's turn (agent rows point at it; a user lead points at
    # nothing). Self-referential, same-table — can never cross tenants because it never crosses sessions.
    belongs_to :user_message, class_name: "Rbrun::SessionMessage", optional: true
    has_many :turn_replies, class_name: "Rbrun::SessionMessage", foreign_key: :user_message_id,
                            inverse_of: :user_message, dependent: :nullify

    # A GATED tool call: nil on ordinary rows; present means this tool_use reached a needs_approval
    # gate (which ended the run — nothing executed), and payload name/input are the frozen action.
    enum :approval_status,
         { pending: "pending", approved: "approved", rejected: "rejected", cancelled: "cancelled" },
         prefix: :approval, validate: { allow_nil: true }

    scope :gated, -> { where.not(approval_status: nil) }

    def tool_use?    = event_type == "tool_use"
    def tool_result? = event_type == "tool_result"
  end
end
```

- [ ] **Step 5: write the model tests**

`test/models/rbrun/session_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class SessionTest < ActiveSupport::TestCase
    test "defaults to idle and stores sdk_session_id" do
      s = Session.create!(tenant: "acme")
      assert s.idle?
      s.update!(sdk_session_id: "sess-123")
      assert_equal "sess-123", s.reload.sdk_session_id
    end

    test "status transitions via the enum" do
      s = Session.create!(tenant: "acme")
      s.working!
      assert s.working?
      s.needs_approval!
      assert s.needs_approval?
    end

    test "has_many messages ordered, dependent destroy" do
      s = Session.create!(tenant: "acme")
      s.messages.create!(role: "user", event_type: "text", content: "hi")
      assert_equal 1, s.messages.count
      assert_difference("Rbrun::SessionMessage.count", -1) { s.destroy }
    end

    test "#sandbox resolves a local box from config" do
      s = Session.create!(tenant: "acme")
      assert_instance_of Rbrun::Sandbox::Local, s.sandbox
    ensure
      s&.sandbox&.destroy!
    end
  end
end
```

`test/models/rbrun/session_message_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class SessionMessageTest < ActiveSupport::TestCase
    setup { @session = Session.create!(tenant: "acme") }

    test "persists an event row verbatim with json payload" do
      m = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t1",
                                    payload: { "name" => "add", "input" => { "a" => 2 } })
      assert_equal "add", m.reload.payload["name"]
      assert m.tool_use?
    end

    test "approval_status enum is prefixed and gated scope finds frozen calls" do
      pending = @session.messages.create!(role: "assistant", event_type: "tool_use",
                                          approval_status: "pending", tool_use_id: "t2")
      @session.messages.create!(role: "assistant", event_type: "text", content: "hi")
      assert pending.approval_pending?
      assert_equal [ pending ], @session.messages.gated.to_a
    end

    test "user_message threads agent rows to the turn lead" do
      lead = @session.messages.create!(role: "user", event_type: "text", content: "do it")
      reply = @session.messages.create!(role: "assistant", event_type: "text", content: "done",
                                        user_message: lead)
      assert_equal lead, reply.user_message
      assert_includes lead.turn_replies, reply
    end
  end
end
```

- [ ] **Step 6: run — verify tenanted + model tests pass**

Run: `bin/rails test test/rbrun/tenanted_test.rb test/models/rbrun/session_test.rb test/models/rbrun/session_message_test.rb`
Expected: PASS. (Tenanted test from Task 2 now green too.)

- [ ] **Step 7: commit**

```bash
git add db/migrate app/models/rbrun/session.rb app/models/rbrun/session_message.rb test/dummy/config/initializers/rbrun.rb test/models/rbrun test/dummy/db
git commit -m "feat(engine): Session + SessionMessage event-log models + migrations"
```

---

### Task 4: `rbrun:install` generator

**Files:**
- Create: `lib/generators/rbrun/install/install_generator.rb`, `lib/generators/rbrun/install/templates/rbrun.rb`
- Test: `test/generators/install_generator_test.rb`

**Interfaces:**
- Produces: `rails generate rbrun:install` → writes `config/initializers/rbrun.rb` (a filled `Rbrun.configure` template) and prints the migration-install + `database.yml` next steps.

- [ ] **Step 1: the generator**

`lib/generators/rbrun/install/install_generator.rb`:

```ruby
require "rails/generators/base"

module Rbrun
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/rbrun.rb and prints the remaining install steps."

      def create_initializer
        template "rbrun.rb", "config/initializers/rbrun.rb"
      end

      def show_next_steps
        say "\nrbrun installed. Next:", :green
        say "  1. Fill in config/initializers/rbrun.rb (API keys, providers)."
        say "  2. If database_connection is :rbrun, add an 'rbrun' entry under each env in config/database.yml."
        say "  3. bin/rails rbrun:install:migrations && bin/rails db:migrate"
      end
    end
  end
end
```

`lib/generators/rbrun/install/templates/rbrun.rb`:

```ruby
# rbrun configuration. See docs for every knob.
Rbrun.configure do |c|
  c.database_connection = :rbrun            # :rbrun (own DB) | :primary (host DB)
  c.subprocess_timeout  = 900
  c.github_pat          = ENV["GITHUB_PAT"] # agent's GitHub access (staged into the sandbox per-turn)
  c.tenancy_key         = "tenant"          # name of the required slug column scoping every record

  # Built-in auth (optional; omit ⇒ your app supplies Rbrun.current_tenant). Repeatable.
  # c.user email: "you@example.com", password: ENV["RBRUN_PW"], tenant: "default"

  c.runtime_provider = {
    default:    :claude_sdk,
    claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_API_KEY"], model: "sonnet", max_turns: 60 }
  }

  c.sandbox_provider = {
    default: :daytona,
    daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] },
    local:   {}
  }
end
```

- [ ] **Step 2: write the failing test**

`test/generators/install_generator_test.rb`:

```ruby
require "test_helper"
require "rails/generators/test_case"
require "generators/rbrun/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Rbrun::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  test "creates the rbrun initializer" do
    run_generator
    assert_file "config/initializers/rbrun.rb", /Rbrun\.configure/, /sandbox_provider/, /tenancy_key/
  end
end
```

- [ ] **Step 3: run — verify fail, then implement (already written), then pass**

Run: `bin/rails test test/generators/install_generator_test.rb`
Expected: PASS once the generator + template exist (created in Step 1).

- [ ] **Step 4: commit**

```bash
git add lib/generators test/generators
git commit -m "feat(engine): rbrun:install generator (config initializer + next steps)"
```

---

### Task 5: Dogfood — the event log persists

**Files:**
- Create: `lib/tasks/rbrun/dogfood/session_log.rake`

**Interfaces:**
- Consumes: `Rbrun::Session`, `Rbrun::SessionMessage`, `Rbrun.sandbox`/`Rbrun.runtime`, `Rbrun::Dogfood`.

- [ ] **Step 1: write the dogfood**

`lib/tasks/rbrun/dogfood/session_log.rake`:

```ruby
# frozen_string_literal: true

require_relative "support"

# Phase 4 dogfood — the persistence + config spine, for real (real DB, real config). Creates a
# Session as a tenant, appends event-log rows exactly as the turn loop will (Phase 5), and proves
# they persist, scope by tenant, thread to their turn, and that the config-aware constructors resolve.
# Needs :environment (the DB + config).
#
#   bin/rails app:dogfood:session_log

namespace :dogfood do
  desc "Phase 4: a Session persists an event log, scopes by tenant, and resolves its sandbox/runtime"
  task session_log: :environment do
    dog = Rbrun::Dogfood

    session = Rbrun::Session.create!(tenant: "dogfood")
    lead = session.messages.create!(role: "user", event_type: "text", content: "build me a report")
    session.messages.create!(role: "assistant", event_type: "session", payload: { "session_id" => "sess-abc" })
    session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t1",
                             user_message: lead, payload: { "name" => "add", "input" => { "a" => 2, "b" => 3 } })
    session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t2",
                             approval_status: "pending", user_message: lead, payload: { "name" => "deploy" })
    session.update!(sdk_session_id: "sess-abc", status: "needs_approval")

    dog.header "persistence"
    dog.ok "session persisted with 4 event rows", session.messages.count == 4
    dog.ok "sdk_session_id stored", session.reload.sdk_session_id == "sess-abc"
    dog.ok "status is needs_approval", session.needs_approval?

    dog.header "tenancy"
    other = Rbrun::Session.create!(tenant: "someone-else")
    dog.ok "for_tenant('dogfood') finds our session", Rbrun::Session.for_tenant("dogfood").include?(session)
    dog.ok "for_tenant('dogfood') excludes the other tenant", !Rbrun::Session.for_tenant("dogfood").include?(other)

    dog.header "event log shape"
    dog.ok "one frozen (gated) tool_use row", session.messages.gated.count == 1
    dog.ok "agent rows thread to the user lead", session.messages.where(user_message_id: lead.id).count == 2

    dog.header "config-aware constructors"
    box = session.sandbox
    dog.ok "session.sandbox resolved from config (:local)", box.is_a?(Rbrun::Sandbox::Local)
    dog.ok "Rbrun.runtime resolves claude_sdk", Rbrun.runtime(sandbox: box).is_a?(Rbrun::Runtime::ClaudeSdk)

    box.destroy!
    session.destroy!
    other.destroy!
    dog.info "cleanup", "sessions destroyed"
  end
end
```

- [ ] **Step 2: run the dogfood**

Run: `bin/rails app:dogfood:session_log`
Expected: all ✓ across persistence / tenancy / event-log shape / config-aware constructors.

- [ ] **Step 3: full verification + commit**

```bash
bin/rails test            # engine green (constructors, tenanted, models, generator)
bin/rubocop               # 0 offenses
(cd gems/rbrun-sandbox && bundle exec rake test)   # 28/0
(cd gems/rbrun-runtime && bundle exec rake test)   # green
git add lib/tasks/rbrun/dogfood/session_log.rake
git commit -m "feat(dogfood): session_log — the event log persists (Phase 4 gate)"
```

---

## Self-Review

**1. Spec coverage (Phase 4 contract):**
- `Rbrun.configure` aggregator (already from Phase 1) + `Rbrun.sandbox`/`Rbrun.runtime` constructors → Task 1. ✓
- `database_connection` toggle on `Rbrun::ApplicationRecord` → Task 2. ✓
- `Session` (status enum, `sdk_session_id`, `#sandbox`) + `SessionMessage` (event log, payload json, approval columns, `tool_use_id`) → Task 3. ✓
- `Rbrun::Tenanted` (configurable `<tenancy_key>` slug, `for_tenant`, default `"rbrun"`) → Task 2 + migration Task 3. ✓
- `rbrun:install` generator + own-DB migrations + mounted in `test/dummy` → Tasks 3–4. ✓
- Dogfood `session_log` (event log persists, no turn) → Task 5. ✓

**2. Placeholder scan:** No TODO/"handle later". `<ts>` in migration filenames is an explicit "use a real timestamp" instruction. Every code block is complete.

**3. Type/name consistency:** `Rbrun.sandbox`/`Rbrun.runtime` over `Rbrun.build`; `Rbrun::Tenanted#for_tenant`/`#tenant` keyed on `Rbrun.config.tenancy_key`; `Session` (`status` enum, `sdk_session_id`, `#sandbox`, `messages`); `SessionMessage` (`approval_status` `:approval`-prefixed enum, `gated`, `user_message`/`turn_replies`); the dummy initializer's `tenancy_key = "tenant"` matches the migration column. `Rbrun::Sandbox::Local` / `Rbrun::Runtime::ClaudeSdk` match the gems.

**Risk area:** engine-migration application to the dummy dev + test DBs (Task 3 Step 3) — the one Rails-plumbing step; if `app:db:migrate` doesn't see the engine migrations, install them first (`app:rbrun:install:migrations`). Validated by the model tests + the `session_log` dogfood.

**Note carried to Phase 5:** `Session#run_turn` will call `Rbrun.runtime(sandbox:).run(prompt:, system:, tools: ApplicationTool.manifest, tool_handler:, on_event:)` and route events into `SessionMessage` via `AgentTurn#ingest`; the models + constructors here are exactly that seam.
