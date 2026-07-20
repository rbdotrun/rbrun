# Repo Services Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Give the agent five `repo_services_*` tools + a `request_secrets` tool so it can run a repo's
long-lived services (with secrets) inside the worktree's sandbox, and rbrun renders status/logs/previews
in a sidebar Services panel.

**Architecture:** Two-layer data (`RepoService` saved per-repo · `ServiceRun` live per-worktree) +
`RepoSecret` (encrypted, per-repo). `ServiceSupervisor` owns the sandbox mechanics (managed sessions +
pidfiles + secret env injection) behind the tool contract, so a systemd/compose backend is a later swap.
Preview is the port facet via an optional `preview_url(port)` sandbox capability probed by `respond_to?`.

**Tech Stack:** Rails 8.1 engine, ViewComponent cards, Turbo Streams, Stimulus, ActiveRecord encryption,
RubyLLM tool base, the pure `rbrun-sandbox` gem.

## Global Constraints

- Ruby 3.4.4, Rails `>= 8.1.3`. Engine tables `rbrun_*`; tenancy column `Rbrun.config.tenancy_key`
  (`"tenant"`), NOT NULL; tenant scope single-arg `for_tenant(slug)`.
- **No registry.** Tools register in `lib/rbrun/engine.rb` `after_initialize` via `Rbrun.register_tool`.
  A `custom_approval!` tool is boot-enforced (card + submit route) → **`request_secrets` registers in the
  same task that builds its card + `:secrets_submission` route (Task 7).** `repo_services_start` is
  `needs_approval!` (card optional, not boot-enforced) → registers in Task 6.
- Tool results string-keyed: `{ "data" => … }` / `{ "error" => "…" }`. `execute` returns, never raises
  for recoverable errors.
- **Secret values never reach the LLM**: not in the tool_use payload, tool_result, resume nudge, or logs.
  Only key names. Values: form → `encrypts`-ed DB → sandbox `.rbrun/env`.
- Pure gem (`rbrun-sandbox`) depends on nothing; `preview_url` lives there; the engine only probes it.
- English copy. Work on `main`. `bin/rails test` after each task; gem tests via its own suite.

## File Structure

- `db/migrate/20260720120000_create_rbrun_repo_services.rb` — 3 tables + Worktree assoc columns already
  on Worktree (none needed; associations only).
- `app/models/rbrun/{repo_service,service_run,repo_secret}.rb`; `worktree.rb` (MODIFY).
- `gems/rbrun-sandbox/lib/rbrun/sandbox/preview_link.rb` (+ require in `sandbox.rb`); `daytona.rb`,
  `daytona/client.rb`, `local.rb` (MODIFY: `preview_url`/`preview_link`).
- `app/services/rbrun/{service_supervisor,service_launcher,service_conventions,secrets_form_spec}.rb`.
- `app/tools/rbrun/tools/{repo_services_start,repo_services_restart,repo_services_stop,repo_services_status,repo_services_logs,request_secrets}.rb`.
- `app/components/rbrun/sessions/tools_validation/{repo_services_start,request_secrets}/component.{rb,html.erb}`.
- `app/controllers/rbrun/{services_controller,secrets_controller}.rb`; `app/jobs/rbrun/{service_log_tail_job,secrets_turn_job}.rb`; `config/routes.rb` (MODIFY).
- `app/services/rbrun/agent_turn.rb` (MODIFY: append conventions); `lib/rbrun/engine.rb` (MODIFY: register + filter_parameters).
- `app/views/layouts/rbrun/_services_panel.html.erb` + `application.html.erb` (MODIFY); `app/helpers/rbrun/application_helper.rb` (current_worktree); `app/javascript/rbrun/controllers/drawer_controller.js` + `rbrun.js`.
- `test/dummy/config/initializers/active_record_encryption.rb` (test keys).
- `lib/tasks/rbrun/dogfood/{repo_services_local,preview_daytona}.rake`.

---

### Task 1: Migration + RepoService, ServiceRun, RepoSecret models

**Files:** create the 3 migration/model files + `worktree.rb` MODIFY; tests
`test/models/rbrun/{repo_service_test,service_run_test,repo_secret_test}.rb`, plus
`test/dummy/config/initializers/active_record_encryption.rb`.

**Interfaces produced:** `Rbrun::RepoService` (Tenanted; validates repo/name/command; unique
[tenant,repo,name]; `scope :for_repo`), `Rbrun::ServiceRun` (belongs_to :worktree; Tenanted inherited;
enum `status` prefix `:status`; `previewable?`), `Rbrun::RepoSecret` (Tenanted; `encrypts :value`; unique
[tenant,repo,key]), `Worktree has_many :service_runs`.

- [ ] **Step 1: AR encryption test keys** — `test/dummy/config/initializers/active_record_encryption.rb`:

```ruby
Rails.application.config.active_record.encryption.primary_key = "test" * 8
Rails.application.config.active_record.encryption.deterministic_key = "det!" * 8
Rails.application.config.active_record.encryption.key_derivation_salt = "salt" * 8
```

- [ ] **Step 2: Migration** `db/migrate/20260720120000_create_rbrun_repo_services.rb`:

```ruby
class CreateRbrunRepoServices < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_repo_services do |t|
      t.string  Rbrun.config.tenancy_key, null: false
      t.string  :repo,    null: false
      t.string  :name,    null: false
      t.string  :command, null: false
      t.integer :port
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :rbrun_repo_services, [ Rbrun.config.tenancy_key, :repo, :name ], unique: true, name: "idx_rbrun_repo_services_uniq"

    create_table :rbrun_service_runs do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string  Rbrun.config.tenancy_key, null: false
      t.string  :name,    null: false
      t.string  :command, null: false
      t.integer :port
      t.string  :status,  null: false, default: "starting"
      t.integer :exit_code
      t.string  :url
      t.string  :token
      t.string  :process_session
      t.string  :cmd_id
      t.integer :log_offset, null: false, default: 0
      t.timestamps
    end
    add_index :rbrun_service_runs, [ :worktree_id, :name ], unique: true

    create_table :rbrun_repo_secrets do |t|
      t.string :tenant_placeholder # replaced below
    end
    drop_table :rbrun_repo_secrets # (guard: recreate cleanly)
    create_table :rbrun_repo_secrets do |t|
      t.string :tenant, null: false
      t.string :repo,   null: false
      t.string :key,    null: false
      t.text   :value
      t.timestamps
    end
    add_index :rbrun_repo_secrets, [ :tenant, :repo, :key ], unique: true, name: "idx_rbrun_repo_secrets_uniq"
  end
end
```

NOTE simplify: drop the placeholder churn — `rbrun_repo_secrets` uses literal `tenant` (the default
tenancy_key) since `RepoSecret` is a plain Tenanted model; if a host renames the key, secrets follow the
default column name `"tenant"` (documented limitation). Final migration uses one clean `create_table
:rbrun_repo_secrets` with `t.string :tenant`.

- [ ] **Step 3: Models**

```ruby
# app/models/rbrun/repo_service.rb
module Rbrun
  class RepoService < ApplicationRecord
    include Rbrun::Tenanted
    validates :repo, :name, :command, presence: true
    scope :for_repo, ->(repo) { where(repo: repo).order(:position) }
  end
end
```
```ruby
# app/models/rbrun/service_run.rb
module Rbrun
  class ServiceRun < ApplicationRecord
    include Rbrun::Tenanted
    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create
    enum :status, { starting: "starting", running: "running", exited: "exited", stopped: "stopped" },
         prefix: :status
    validates :name, :command, presence: true
    def previewable? = port.present? && url.present?
    private
    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
  end
end
```
```ruby
# app/models/rbrun/repo_secret.rb
module Rbrun
  class RepoSecret < ApplicationRecord
    include Rbrun::Tenanted
    encrypts :value
    validates :repo, :key, presence: true
    scope :for_repo, ->(repo) { where(repo: repo) }
  end
end
```

- [ ] **Step 4: Worktree assoc** — add to `app/models/rbrun/worktree.rb` after `has_many :commits`:

```ruby
    has_many :service_runs, class_name: "Rbrun::ServiceRun", dependent: :destroy
```

- [ ] **Step 5: Tests** (representative assertions)

```ruby
# test/models/rbrun/repo_secret_test.rb
require "test_helper"
module Rbrun
  class RepoSecretTest < ActiveSupport::TestCase
    test "value is encrypted at rest, readable via the model" do
      s = Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "RAILS_MASTER_KEY", value: "supersecret")
      assert_equal "supersecret", s.reload.value
      raw = Rbrun::RepoSecret.connection.select_value("select value from rbrun_repo_secrets where id=#{s.id}")
      refute_includes raw.to_s, "supersecret", "ciphertext at rest"
    end
    test "unique per [tenant, repo, key]" do
      Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "K", value: "1")
      assert_raises(ActiveRecord::RecordNotUnique) { Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "K", value: "2") }
    end
  end
end
```
```ruby
# test/models/rbrun/service_run_test.rb — status enum, tenant inheritance, previewable?
# test/models/rbrun/repo_service_test.rb — for_repo ordering, uniqueness
```

- [ ] **Step 6:** `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/rbrun/repo_secret_test.rb test/models/rbrun/service_run_test.rb test/models/rbrun/repo_service_test.rb` → PASS. **Commit.**

---

### Task 2: Preview capability in the sandbox gem

**Files:** `gems/rbrun-sandbox/lib/rbrun/sandbox/preview_link.rb` (create) + require in `sandbox.rb`;
`local.rb`, `daytona.rb`, `daytona/client.rb` (MODIFY); gem tests `local_test.rb`,
`daytona_adapter_test.rb`.

**Interfaces produced:** `Rbrun::Sandbox::PreviewLink = Data.define(:url, :token)`; `Local#preview_url` +
`Daytona#preview_url`; `Client#preview_link(id, port)`.

- [ ] **Step 1** `preview_link.rb`:
```ruby
# frozen_string_literal: true
module Rbrun
  module Sandbox
    # A resolved preview: the public URL for a port inside a box, and the auth token (nil for public /
    # localhost). Optional capability — only adapters that can publish a port return one.
    PreviewLink = Data.define(:url, :token)
  end
end
```
Add `require "rbrun/sandbox/preview_link"` in `sandbox.rb`.

- [ ] **Step 2** `Local#preview_url` (append to Local):
```ruby
      # A local box runs on the host, so the port IS reachable at localhost — no proxy, no token.
      def preview_url(port) = PreviewLink.new(url: "http://localhost:#{port}", token: nil)
```

- [ ] **Step 3** `Daytona#preview_url` + `Client#preview_link`:
```ruby
      # Daytona (adapter): the box's public preview for a port, via the proxy. VERIFY the exact wire in
      # the preview_daytona dogfood; keep the shape { url, token }.
      def preview_url(port)
        raw = @client.preview_link(id, port)
        PreviewLink.new(url: raw["url"], token: raw["token"])
      end
```
```ruby
        # Client: GET the port preview. Endpoint/field names verified live in the dogfood.
        def preview_link(id, port)
          get("#{@api_url}/sandbox/#{id}/ports/#{port}/preview-url")
        end
```

- [ ] **Step 4: Gem tests — NO fakes.** Test `Local#preview_url` for real: `Local.new(config: { root:
  Dir.mktmpdir }, labels: {}).preview_url(3000)` ⇒ `PreviewLink(url: "http://localhost:3000", token:
  nil)`, and `respond_to?(:preview_url)` true. For Daytona, assert only the **capability is present**
  without a fake or live call: `Rbrun::Sandbox::Daytona.instance_methods.include?(:preview_url)` and
  `Rbrun::Sandbox::Daytona::Client.instance_methods.include?(:preview_link)`. **The Daytona preview wire
  (endpoint path + `{url,token}` shape) is verified live in the `preview_daytona` dogfood — not a stubbed
  fake here.** (Do NOT extend the existing `FakeClient`; its refactor to WebMock is a later, separate
  cleanup.)

- [ ] **Step 5:** run the gem suite → PASS. **Commit.**

---

### Task 3: ServiceSupervisor (sandbox mechanics + secret injection)

**Files:** `app/services/rbrun/service_supervisor.rb`; test
`test/services/rbrun/service_supervisor_test.rb` (uses the `Local` sandbox via a real Worktree).

**Interfaces produced:** `ServiceSupervisor.new(worktree:)` with `launch(run)`, `stop(run)`,
`refresh_status(run)`, `write_env!`. Uses `sandbox.session_create/session_exec/exec/session_command`.

- [ ] **Step 1** implement:
```ruby
module Rbrun
  # Owns the sandbox-level mechanics of a service: env injection, launch under a managed process
  # session (pidfile-stoppable), stop, and status. Behind the tool contract so a systemd/compose backend
  # is a later swap. v1 = managed sessions + pidfiles.
  class ServiceSupervisor
    def initialize(worktree:)
      @worktree = worktree
      @sandbox  = worktree.sandbox
    end

    # Write the repo's secrets to a 600 env file the launch wrapper sources. Values reach the sandbox,
    # never the conversation.
    def write_env!
      secrets = Rbrun::RepoSecret.for_tenant(@worktree.tenant).for_repo(@worktree.repo)
      body = secrets.map { |s| "export #{s.key}=#{Shellwords.escape(s.value.to_s)}" }.join("\n")
      @sandbox.exec("mkdir -p #{ws}/.rbrun && umask 177 && cat > #{ws}/.rbrun/env <<'RBRUN_ENV'\n#{body}\nRBRUN_ENV")
    end

    # Start `run.command` as a managed session, pidfile-stoppable, secrets sourced. Records session/cmd.
    def launch(run)
      sess = "svc-#{@worktree.id}-#{run.name}"
      @sandbox.session_create(sess)
      wrapped = "cd #{ws} && mkdir -p .rbrun && set -a && [ -f .rbrun/env ] && . .rbrun/env; set +a; " \
                "echo $$ > .rbrun/#{pidfile(run)}; exec #{run.command}"
      cmd_id = @sandbox.session_exec(sess, "sh -lc #{Shellwords.escape(wrapped)}")
      run.update!(process_session: sess, cmd_id: cmd_id, status: "running", log_offset: 0)
    end

    def stop(run)
      @sandbox.exec("kill $(cat #{ws}/.rbrun/#{pidfile(run)} 2>/dev/null) 2>/dev/null; true")
      run.update!(status: "stopped")
    end

    # exitCode present ⇒ exited (record it). Cheap; called on load / status / recheck.
    def refresh_status(run)
      return run if run.status_stopped? || run.cmd_id.blank?
      info = @sandbox.session_command(run.process_session, run.cmd_id)
      code = info.is_a?(Hash) ? info["exitCode"] : nil
      run.update!(status: "exited", exit_code: code.to_i) unless code.nil?
      run
    end

    private
    def ws = @sandbox.workspace
    def pidfile(run) = "svc-#{run.name}.pid"
  end
end
```
Add `require "shellwords"` at top.

- [ ] **Step 2: Test** — real Worktree + Local sandbox; create a RepoSecret; `write_env!`; `launch` a run
whose command is `sh -c 'echo $MY_SECRET; sleep 5'`; assert `run.status_running?`, `cmd_id` present;
`stop` flips `stopped`. (Local sandbox executes real processes.) Assert the secret's *effect* via logs in
Task 8's job; here assert env file exists (`sandbox.exist?(".rbrun/env")`).

- [ ] **Step 3:** run the test → PASS. **Commit.**

---

### Task 4: ServiceLauncher (orchestration + saved set + broadcast)

**Files:** `app/services/rbrun/service_launcher.rb`; test `test/services/rbrun/service_launcher_test.rb`.

**Interfaces produced:** `ServiceLauncher.new(worktree:)` — `start(services)` (idempotent kill-all +
upsert RepoService + launch each + resolve preview_url + broadcast), `restart(name)`, `stop(name: nil)`,
`status`, `restart_saved`. Broadcasts via `ServiceRun` callbacks (Task 8 wires the partial; here just the
data ops + a `broadcast_panel` hook that Task 8 fills — for now `Rbrun::ServiceRun` broadcasts on
create/update/destroy).

- [ ] **Step 1** implement `start` (the idempotent reset):
```ruby
module Rbrun
  class ServiceLauncher
    Service = Data.define(:name, :command, :port)

    def initialize(worktree:)
      @worktree = worktree
      @sup = Rbrun::ServiceSupervisor.new(worktree: worktree)
    end

    # Idempotent reset: stop+clear all runs, upsert the repo's saved set, launch fresh, resolve previews.
    def start(services)
      list = normalize(services)
      stop_all
      upsert_saved(list)
      @sup.write_env!
      list.map { |svc| launch_one(svc) }
    end

    def restart(name)
      run = find(name) or return nil
      @sup.stop(run); @sup.launch(run); resolve_preview(run); run
    end

    def stop(name: nil)
      (name ? [ find(name) ].compact : @worktree.service_runs).each { |r| @sup.stop(r) }
    end

    def status = @worktree.service_runs.map { |r| @sup.refresh_status(r) }

    def restart_saved
      saved = Rbrun::RepoService.for_tenant(@worktree.tenant).for_repo(@worktree.repo)
      start(saved.map { |s| { "name" => s.name, "command" => s.command, "port" => s.port } })
    end

    private

    def normalize(services)
      Array(services).map { |s| s = s.transform_keys(&:to_s); Service.new(s["name"].to_s, s["command"].to_s, s["port"]) }
                     .reject { |s| s.name.empty? || s.command.empty? }
    end

    def stop_all
      @worktree.service_runs.each { |r| @sup.stop(r) }
      @worktree.service_runs.destroy_all
    end

    def upsert_saved(list)
      list.each_with_index do |svc, i|
        rec = Rbrun::RepoService.for_tenant(@worktree.tenant).find_or_initialize_by(repo: @worktree.repo, name: svc.name)
        rec[Rbrun.config.tenancy_key] = @worktree.tenant
        rec.update!(command: svc.command, port: svc.port, position: i)
      end
    end

    def launch_one(svc)
      run = @worktree.service_runs.create!(name: svc.name, command: svc.command, port: svc.port, status: "starting")
      @sup.launch(run)
      resolve_preview(run)
      run
    end

    def resolve_preview(run)
      return run unless run.port.present? && @worktree.previews_supported?
      link = @worktree.sandbox.preview_url(run.port)
      run.update!(url: link.url, token: link.token)
      run
    end

    def find(name) = @worktree.service_runs.find_by(name: name)
  end
end
```

- [ ] **Step 2** add `Worktree#previews_supported?`:
```ruby
    def previews_supported? = sandbox.respond_to?(:preview_url)
```

- [ ] **Step 3: Test** (Local): `start([{name:"web",command:"sh -c 'sleep 5'",port:4321},{name:"worker",command:"sh -c 'sleep 5'"}])`; assert two `ServiceRun`s running, web `previewable?` with `url == "http://localhost:4321"`, worker not previewable; two `RepoService` saved; a second `start([...])` is idempotent (still 1 web run, not 2); `restart("web")` keeps one; `stop` flips stopped; `restart_saved` relaunches from saved.

- [ ] **Step 4:** PASS. **Commit.**

---

### Task 5: The five repo_services_* tools

**Files:** the 5 tool files; register in `lib/rbrun/engine.rb`; card
`tools_validation/repo_services_start/component.{rb,html.erb}`; test
`test/tools/rbrun/repo_services_tools_test.rb`.

**Interfaces produced:** `Rbrun::Tools::{RepoServicesStart(needs_approval!),RepoServicesRestart,RepoServicesStop,RepoServicesStatus,RepoServicesLogs}`; each `execute` delegates to `ServiceLauncher`/`ServiceSupervisor`.

- [ ] **Step 1** `repo_services_start` (needs_approval!):
```ruby
module Rbrun
  module Tools
    class RepoServicesStart < Rbrun::ApplicationTool
      needs_approval!
      description <<~TXT
        Start this repo's long-lived services (web servers, workers, databases, queues) — the sanctioned
        way to run anything that keeps running, so it is visible, previewable, and debuggable. Idempotent
        reset: stops everything running in this worktree then starts the declared set. Saves the set for
        reuse. Give each service a short `name`, its `command`, and a `port` ONLY if it serves HTTP.
        Example: { "services": [ { "name": "web", "command": "bin/rails s -p 3000", "port": 3000 },
                                  { "name": "css", "command": "bin/rails tailwindcss:watch" } ] }
      TXT
      parameter :services, type: "array",
                items: -> { { "type" => "object" } },
                description: "the services: [{ name, command, port? }]", required: true
      def execute(services:)
        Rbrun::ServiceLauncher.new(worktree: session.worktree).start(services)
        { "data" => { "services" => Rbrun::ServiceLauncher.new(worktree: session.worktree)
                        .status.map { |r| { "name" => r.name, "port" => r.port, "status" => r.status, "url" => r.url } } } }
      end
    end
  end
end
```

- [ ] **Step 2** the four ungated tools (`restart`/`stop`/`status`/`logs`). `logs` reads a bounded tail:
```ruby
# repo_services_logs
def execute(name:, tail: 200)
  run = session.worktree.service_runs.find_by(name: name) or return error("no such service: #{name}")
  out = +""
  begin
    session.worktree.sandbox.session_logs_follow(run.process_session, run.cmd_id, skip: 0, timeout: 3) { |c| out << c; false }
  rescue Rbrun::Sandbox::TimeoutError
    # bounded read — a live server never closes the stream
  end
  { "data" => { "name" => name, "logs" => out.lines.last(tail.to_i).join } }
end
```
`status` → `ServiceLauncher#status` mapped. `restart`/`stop` → launcher, return `{data:{...}}`.

- [ ] **Step 3** register in `engine.rb` after AskUser/workflow tools (before `validate_tool_approvals!`):
```ruby
      [ Rbrun::Tools::RepoServicesStart, Rbrun::Tools::RepoServicesRestart, Rbrun::Tools::RepoServicesStop,
        Rbrun::Tools::RepoServicesStatus, Rbrun::Tools::RepoServicesLogs ].each { |t| Rbrun.register_tool(t) }
```

- [ ] **Step 4** the start gate card (`ToolsValidation::RepoServicesStart::Component` + erb) — lists the
proposed services (name/command/port) + shared `approval_actions`. Fallback-safe (needs_approval).

- [ ] **Step 5: Tests** — instantiate tools `.in_session(session)` on a Local worktree: `start` launches +
saves; `status` reflects; `logs` returns output for a service that echoes; `stop`/`restart` work. Manifest
marks only `repo_services_start` needs_approval.

- [ ] **Step 6:** `bin/rails test` (boot must stay green with tools registered) → PASS. **Commit.**

---

### Task 6: Secrets read-model + storage plumbing

**Files:** `app/services/rbrun/secrets_form_spec.rb`; `lib/rbrun/engine.rb` (MODIFY: filter_parameters);
test `test/services/rbrun/secrets_form_spec_test.rb`.

**Interfaces produced:** `Rbrun::SecretsFormSpec` — `keys`, `label_for`, `required?`, `errors(submitted)`
(required present + no unknown keys), `stored_recap(keys)` (KEY NAMES ONLY).

- [ ] **Step 1** implement (mirrors AskUserFormSpec; **no value ever in recap**):
```ruby
module Rbrun
  class SecretsFormSpec
    def initialize(spec) = @spec = spec || {}
    def secrets = Array(@spec["secrets"])
    def keys = secrets.map { |s| s["key"].to_s }
    def entry(key) = secrets.find { |s| s["key"].to_s == key.to_s }
    def label_for(key) = entry(key)&.dig("label").presence || key
    def required?(key) = !!entry(key)&.dig("required")
    def errors(submitted)
      submitted ||= {}
      msgs = []
      keys.each { |k| msgs << "#{label_for(k)} is required" if required?(k) && submitted[k].to_s.strip.empty? }
      unknown = submitted.keys.map(&:to_s) - keys
      msgs << "unknown fields: #{unknown.join(', ')}" if unknown.any?
      msgs
    end
    # KEYS ONLY — never a value.
    def stored_recap(stored_keys) = "Stored #{stored_keys.join(', ')}. Continue — the secrets are set in the environment (you never see the values)."
  end
end
```

- [ ] **Step 2** engine `filter_parameters` (in `engine.rb`, an initializer block):
```ruby
    initializer "rbrun.filter_parameters" do |app|
      app.config.filter_parameters += [ :secrets, :value ]
    end
```

- [ ] **Step 3: Test** — spec with value≠label secret; `errors` clean when required present; flags a
missing required + unknown keys; `stored_recap(%w[RAILS_MASTER_KEY]).exclude?(secretvalue)` (recap has
only keys).

- [ ] **Step 4:** PASS. **Commit.**

---

### Task 7: request_secrets tool + card + controller + route (custom_approval!)

**Files:** `app/tools/rbrun/tools/request_secrets.rb`;
`app/components/rbrun/sessions/tools_validation/request_secrets/component.{rb,html.erb}`;
`app/controllers/rbrun/secrets_controller.rb`; `app/jobs/rbrun/secrets_turn_job.rb`; `config/routes.rb`
(MODIFY); register in `engine.rb`; tests `test/controllers/rbrun/secrets_flow_test.rb`.

**Interfaces produced:** `Rbrun::Tools::RequestSecrets` (`custom_approval! submit: :secrets_submission`);
`SecretsController#create` (ResolvesGate). Boot-enforced card + route land HERE, same task as registration.

- [ ] **Step 1** route (after ask_user/workflow routes):
```ruby
  post "secrets/:tool_use_id", to: "secrets#create", as: :secrets_submission
```

- [ ] **Step 2** tool:
```ruby
module Rbrun
  module Tools
    class RequestSecrets < Rbrun::ApplicationTool
      custom_approval! submit: :secrets_submission
      description <<~TXT
        Ask the user to provide secrets/environment values the app needs to run (API keys, RAILS_MASTER_KEY,
        DB passwords). Declare only the KEYS you need — you will NEVER see the values; they are stored
        securely and injected into the services' environment. The run pauses for a secure form.
        Example: { "secrets": [ { "key": "RAILS_MASTER_KEY", "label": "Rails master key", "required": true,
                                  "hint": "from config/master.key" } ] }
      TXT
      parameter :secrets, type: "array", items: -> { { "type" => "object" } },
                description: "the secrets to request: [{ key, label, required?, hint? }]", required: true
    end
  end
end
```

- [ ] **Step 3** controller (ResolvesGate; encrypt+store; keys-only tool_result + nudge):
```ruby
module Rbrun
  class SecretsController < Rbrun::ApplicationController
    include Rbrun::ResolvesGate
    def create
      row  = pending_gate
      spec = Rbrun::SecretsFormSpec.new(row.payload.dig("input"))
      submitted = submitted_secrets
      errors = spec.errors(submitted)
      return render(plain: errors.join("; "), status: :unprocessable_entity) if errors.any?
      return head :no_content unless claim_gate!(row, status: "answered")

      repo = row.session.worktree.repo
      stored = []
      submitted.slice(*spec.keys).each do |key, value|
        next if value.to_s.empty?
        rec = Rbrun::RepoSecret.for_tenant(row.session.tenant).find_or_initialize_by(repo: repo, key: key)
        rec[Rbrun.config.tenancy_key] = row.session.tenant
        rec.update!(value: value)
        stored << key
      end
      record_gate_result(row, { "stored_keys" => stored }) # KEYS ONLY
      resume_turn(row, SecretsTurnJob, spec.stored_recap(stored))
      render_gate_band(row)
    end
    private
    def submitted_secrets
      raw = params[:secrets]
      return {} if raw.blank?
      (raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw).to_h { |k, v| [ k.to_s, v.to_s ] }
    end
  end
end
```

- [ ] **Step 4** job `SecretsTurnJob(session_id, nudge) → continue_turn!(nudge)`.

- [ ] **Step 5** card — password input per key (component DSL), answered state shows key names only:
```erb
<div class="border-t border-slate-200 p-3">
  <% if answered? %>
    <p class="text-sm text-slate-700">Stored: <%= stored_keys.join(", ") %>.</p>
  <% else %>
    <%= form_with url: submit_path, method: :post, class: "flex flex-col gap-3" do %>
      <% spec.keys.each do |key| %>
        <label class="flex flex-col gap-1 text-sm">
          <span class="font-medium text-slate-700"><%= spec.label_for(key) %></span>
          <% if (h = spec.entry(key)&.dig("hint")).present? %><span class="text-xs text-slate-400"><%= h %></span><% end %>
          <input type="password" name="secrets[<%= key %>]" autocomplete="off" <%= "required" if spec.required?(key) %>
                 class="rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-default-500 focus:outline-none">
        </label>
      <% end %>
      <div class="flex items-center gap-2 pt-1">
        <%= component("button", variant: :primary, size: :sm, type: "submit") do %>Save secrets<% end %>
        <span class="ml-auto text-[11px] text-slate-400">Values are stored securely; the agent never sees them.</span>
      </div>
    <% end %>
  <% end %>
</div>
```
Component `#answered? = @call.approval_answered?`; `#stored_keys` from the tool_result `stored_keys`;
`#spec = SecretsFormSpec.new(input)`; `#submit_path = helpers.rbrun.secrets_submission_path(tool_use_id)`.

- [ ] **Step 6** register in `engine.rb`: `Rbrun.register_tool(Rbrun::Tools::RequestSecrets)` (before
`validate_tool_approvals!`, which now finds its card + route).

- [ ] **Step 7: Tests** — `secrets_flow_test.rb` (integration, value≠key): the card renders password
inputs posting to `/rbrun/secrets/<id>`; a valid submit encrypts a `RepoSecret`, records a tool_result of
**stored_keys only** (assert the value string is NOT anywhere in the result payload/nudge), resumes with a
keys-only nudge; a missing required → 422 nothing claimed; unknown field → 422; double submit no-op.

- [ ] **Step 8:** `bin/rails test` (boot green — custom_approval! satisfied) → PASS. **Commit.**

---

### Task 8: System-prompt convention + AgentTurn append

**Files:** `app/services/rbrun/service_conventions.rb`; `app/services/rbrun/agent_turn.rb` (MODIFY); test
`test/services/rbrun/agent_turn_system_prompt_test.rb`.

- [ ] **Step 1** `ServiceConventions::PROMPT` (the §2 text). Constant string.

- [ ] **Step 2** in `AgentTurn#call_client`, change `system:`:
```ruby
        system: [ Rbrun.config(@session.tenant).system_prompt, Rbrun::ServiceConventions::PROMPT ].join("\n\n"),
```

- [ ] **Step 3: Test** — stub runtime capturing `system:`; assert it contains both the host prompt and
"repo_services_start" / "never a raw `&`". (Reuse the existing AgentTurn test harness/fake runtime.)

- [ ] **Step 4:** PASS. **Commit.**

---

### Task 9: Services panel UI + controller + logs drawer

**Files:** `app/helpers/rbrun/application_helper.rb` (current_worktree);
`app/views/layouts/rbrun/_services_panel.html.erb` + `application.html.erb` (MODIFY);
`app/models/rbrun/service_run.rb` (MODIFY: broadcasts); `app/controllers/rbrun/services_controller.rb` +
routes; `app/jobs/rbrun/service_log_tail_job.rb`; `app/javascript/rbrun/controllers/drawer_controller.js`
+ `rbrun.js` (rebuild); tests `test/controllers/rbrun/services_panel_test.rb`.

- [ ] **Step 1** `current_worktree` helper = `@session&.worktree`. Subscribe layout to
`turbo_stream_from "rbrun_worktree_#{current_worktree.id}"` when present; render `_services_panel` under
the repo switcher.

- [ ] **Step 2** `ServiceRun` broadcasts (worktree stream) on create/update/destroy → replace
`#services_panel_<worktree_id>` (re-render the panel partial). Panel refreshes each run's status via
`ServiceSupervisor#refresh_status` on load.

- [ ] **Step 3** panel partial: rows `● name :port? status` + `[Logs][Stop][Restart]` + `[Open ↗]` when
`previewable?`; a **Restart all** when no runs but `RepoService.for_repo` non-empty. Buttons →
`ServicesController` (open/stop/restart/restart_all) via `button_to`.

- [ ] **Step 4** `ServicesController`: `open` (GET → 302 to run.url, new tab target on the link),
`stop`/`restart`/`restart_all` (→ ServiceLauncher, broadcast), `logs` (renders the drawer, enqueues
`ServiceLogTailJob`). Routes `resources :services, only: [] do member { get :open; post :stop; post :restart; get :logs } end; post "services/restart_all"`.

- [ ] **Step 5** `ServiceLogTailJob` follows `session_logs_follow(bounded)` and Turbo-appends to
`#service_<id>_logs`, updating `log_offset`.

- [ ] **Step 6** `drawer_controller.js` (slide-over open/close), register in `rbrun.js`, `bun run build`.

- [ ] **Step 7: Tests** — panel renders rows for running services incl. `[Open ↗]` for previewable; a
non-previewable service has no Open; `stop`/`restart_all` hit the launcher; `open` redirects to the url.

- [ ] **Step 8:** `bin/rails test` + `bun run build` committed → PASS. **Commit.**

---

### Task 10: Dogfoods

**Files:** `lib/tasks/rbrun/dogfood/repo_services_local.rake`,
`lib/tasks/rbrun/dogfood/preview_daytona.rake` (+ reuse `support.rb`).

- [ ] **Step 1** `repo_services_local` (offline; real Claude, Local sandbox): drive `request_secrets`
(submit a `MY_SECRET` via the SecretsController path without HTTP, asserting value never in tool_result),
`repo_services_start` a `$MY_SECRET`-echoing service + an HTTP one (`python3 -m http.server PORT` or a bun
one-liner), assert rows `running`, HTTP `url == http://localhost:PORT` serves (curl in-process), logs tail
shows output, `restart`, `stop` → `stopped`, second `start` idempotent. **Run it** (offline gate).

- [ ] **Step 2** `preview_daytona` (live; **write, do NOT run**): custom ruby+node+postgres Dockerfile;
provision `benbonnet/dummy-rails`; `request_secrets` submits `RAILS_MASTER_KEY` read from
`/Users/ben/Desktop/sources/dummy-rails/config/master.key` (harness stands in for the user); start
postgres + `bin/rails server -p 3000` (+ `db:prepare`); resolve `preview_url`; verify the token mechanism
through `services/:id/open` against the live app. Header comment: "fired manually — needs Daytona creds".

- [ ] **Step 3** `bin/rails app:dogfood:repo_services_local` → green ✓ signals. **Commit both.** (Do NOT
run `preview_daytona`.)

---

## Self-Review

- **Spec coverage:** tools §1 (T5) · soft convention §2 (T8) · data §3 (T1) · supervision §4 (T3) ·
  preview capability §5 (T2) · UI §6 (T9) · token seam §7 (T9 open endpoint, T10 verify) · secrets §8
  (T6/T7) · dogfoods §11 (T10). ✓
- **Boot ordering:** `request_secrets` (custom_approval!, boot-enforced) registers in T7 with its card +
  `:secrets_submission` route — never before. `repo_services_start` (needs_approval!) in T5.
- **Secret non-leak:** value path is form → `encrypts` DB → `.rbrun/env`; tool_result/nudge = keys only
  (T7 asserts the value string is absent from the payload); `filter_parameters` (T6). ✓
- **Type consistency:** `ServiceLauncher.start(services)` accepts string/symbol-keyed hashes (normalize);
  `ServiceRun.status` enum values match everywhere; `PreviewLink(url:, token:)` used identically in
  gem + launcher; tool results all `{ "data" => … }`.
- **Idempotency:** `start` = stop_all + destroy_all + fresh (T4 asserts a second start ≠ duplicate rows).
- **Live-verify flagged:** Daytona `preview_link` endpoint + token mechanism are the only unverified wire,
  isolated to `Client#preview_link` + `services/:id/open`, closed by the (unrun) `preview_daytona`.
