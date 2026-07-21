# rbrun-server + deploy tools + preview-deploy skill — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `:server` provider family (`gems/rbrun-server/`) + engine deploy tools + a `preview-deploy` skill, so the agent can take a worktree from sandbox code to a Kamal-deployed, DNS-pointed, publicly reachable app — replacing the removed local `bin/dev` scripts.

**Architecture:** A pure gem `Rbrun::Server` (family `:server`) resolves an adapter by constant lookup (no registry); `KamalHetzner` provisions via the Hetzner Cloud API (Faraday/async-http) and deploys via Kamal's local builder. The engine composition root adds `Rbrun.server`. A `Rbrun::DeployTarget` record is `has_one` per `Worktree` (mirroring `ServiceExposure`). Six worktree-scoped tools drive provision → dns → prepare → deploy → teardown. A DB-seeded `preview-deploy` skill carries the Dockerfile/Kamal templates.

**Tech Stack:** Ruby 3.4.4 (gem floor `>= 3.2`), Rails `>= 8.1.3`, Faraday 2 on async-http, Kamal, RubyLLM (engine tools only), Minitest + WebMock.

**Design of record:** `docs/superpowers/specs/2026-07-21-rbrun-server-deploy-design.md`.

## ⚠️ CORRECTED ARCHITECTURE (supersedes any drift in the tasks below)

The division of labor is fixed (spec §0). **Do not blur it:**

- **Agent + `rails-kamal-deployment` skill = repo prep.** The agent inspects the repo and, IF MISSING, adds
  `Dockerfile` + `config/deploy.yml` (reading the `KAMAL_*` env), fixes `Gemfile.lock`, adds a DB accessory +
  `.kamal/secrets`, then **commits + pushes**. The engine writes **no** repo files.
- **Engine = infra + enforcement.** provision · dns · expose the `KAMAL_*` env · clone the **pushed** branch ·
  run kamal. `deploy` **blocks unless the branch is committed + pushed** (`DeployRunner.branch_pushed?`).
  `DeployRunner` does **no** config injection and **no** repo-prep. Version = commit sha.
- **Tools are SIX:** `provision_server`, `create_deploy_dns`, `deploy` (gated + push-enforced), `deploy_status`,
  `deploy_logs`, `teardown_deploy`. **Removed:** `prepare_deploy` (agent writes the files) and `save_deploy_tag`
  (the sha IS the tag). **Removed service:** `DeployScaffold`.
- **SSH keys are per-deployment, ours:** `DeployKeys.ensure!` generates + stores the keypair on `DeployTarget`;
  the adapter takes keys per call (not config).
- **Skill folder is `app/skills/rails-kamal-deployment/`** (replaces `preview-deploy`).
- **Proof = a real agent turn**, not a synthetic rake dogfood: the agent (skill-guided) preps `DOGFOOD_APP_REPO`,
  commits+pushes, and drives the tools to a live URL.

## Global Constraints

Every task's requirements implicitly include these (verbatim from CLAUDE.md invariants + the spec):

- **No registry, no self-registration.** Adapter resolution is constant lookup in `Rbrun::Server`. The gem depends on **no other rbrun gem** (external deps `faraday`/`async-http`/`kamal` only).
- **Engine is the only composition root.** The pure gem takes an explicit `config:` hash and reads no global state. Only `Rbrun.server` (engine) reads `Rbrun.configure`. The adapter **validates its own config, fail-fast**.
- **All outbound HTTP is Faraday on the `async-http` adapter.** Never the `hcloud` CLI, never a vendor SDK.
- **Own DB + always-on tenancy.** `DeployTarget` carries the `Rbrun.config.tenancy_key` column and inherits the tenant from its worktree.
- **RubyLLM is engine-only** — it must never appear in the gem.
- **Deploy is a human decision.** The `deploy` tool is `needs_approval!` (invariant #10's spirit).
- **Idempotency is mandatory (invariant #11).** Find-or-create server (by name), upsert DNS, upsert setup files; `teardown_deploy` destroys the server + DNS and resets the row.
- **Provider adapters are tested against a stubbed WIRE (WebMock), never a hand fake.** Suite runs green under `bin/rails test`; the gem's own suite under its Rakefile.
- **Dogfood: one scenario per file, never variabilized** (no ENV/toggles), reaps its infra in `ensure`.

---

### Task 1: Gem scaffold — `Rbrun::Server` family, `Base` interface, value objects

**Files:**
- Create: `gems/rbrun-server/rbrun-server.gemspec`
- Create: `gems/rbrun-server/Rakefile`
- Create: `gems/rbrun-server/README.md`
- Create: `gems/rbrun-server/lib/rbrun/server/version.rb`
- Create: `gems/rbrun-server/lib/rbrun/server.rb`
- Create: `gems/rbrun-server/lib/rbrun/server/base.rb`
- Create: `gems/rbrun-server/lib/rbrun/server/node.rb`
- Create: `gems/rbrun-server/lib/rbrun/server/deploy_result.rb`
- Create: `gems/rbrun-server/test/test_helper.rb`
- Test: `gems/rbrun-server/test/rbrun/server/server_test.rb`

**Interfaces:**
- Produces:
  - `Rbrun::Server.new(provider:, config: {}, **opts)` → adapter instance (constant lookup via `ADAPTERS = { kamal_hetzner: "KamalHetzner" }`).
  - `Rbrun::Server::Error < StandardError`.
  - `Rbrun::Server::Base` with `create_server(name:, type:, region:, image:, ssh_keys: [], user_data: nil, labels: {})`, `find_server(name:)`, `list_servers(label: nil)`, `destroy_server(name:)`, `deploy(work_dir:, host:, server_ip:, env: {})` — each `raise NotImplementedError`.
  - `Rbrun::Server::Node = Data.define(:id, :name, :ip, :status, :region)`.
  - `Rbrun::Server::DeployResult = Data.define(:ok, :output)`.

- [ ] **Step 1: Write the failing test**

`gems/rbrun-server/test/test_helper.rb`:
```ruby
# frozen_string_literal: true
require "minitest/autorun"
require "webmock/minitest"
require "rbrun/server"
WebMock.disable_net_connect!
```

`gems/rbrun-server/test/rbrun/server/server_test.rb`:
```ruby
# frozen_string_literal: true
require "test_helper"

class ServerTest < Minitest::Test
  def test_resolves_the_adapter_by_constant_lookup
    srv = Rbrun::Server.new(provider: :kamal_hetzner,
                            config: { hcloud_token: "t", ssh_public_key: "k", ssh_private_key: "p",
                                      registry: { server: "docker.io", username: "u", password: "pw" } })
    assert_instance_of Rbrun::Server::KamalHetzner, srv
  end

  def test_unknown_provider_fails_loud
    error = assert_raises(Rbrun::Server::Error) { Rbrun::Server.new(provider: :aws, config: {}) }
    assert_match(/unknown server provider :aws/, error.message)
  end

  def test_base_methods_are_unimplemented_until_overridden
    base = Rbrun::Server::Base.new
    assert_raises(NotImplementedError) { base.create_server(name: "x", type: "cx23", region: "fsn1", image: "ubuntu-24.04") }
    assert_raises(NotImplementedError) { base.find_server(name: "x") }
    assert_raises(NotImplementedError) { base.list_servers }
    assert_raises(NotImplementedError) { base.destroy_server(name: "x") }
    assert_raises(NotImplementedError) { base.deploy(work_dir: "/tmp", host: "h", server_ip: "1.2.3.4") }
  end

  def test_node_and_deploy_result_are_value_objects
    n = Rbrun::Server::Node.new(id: 1, name: "x", ip: "1.2.3.4", status: "running", region: "fsn1")
    assert_equal "1.2.3.4", n.ip
    assert Rbrun::Server::DeployResult.new(ok: true, output: "done").ok
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd gems/rbrun-server && bundle exec rake test`
Expected: FAIL — `cannot load such file -- rbrun/server`.

- [ ] **Step 3: Write the gem files**

`gems/rbrun-server/lib/rbrun/server/version.rb`:
```ruby
# frozen_string_literal: true
module Rbrun
  module Server
    VERSION = "0.1.0"
  end
end
```

`gems/rbrun-server/lib/rbrun/server.rb`:
```ruby
# frozen_string_literal: true
require "rbrun/server/version"
require "rbrun/server/node"
require "rbrun/server/deploy_result"
require "rbrun/server/base"
require "rbrun/server/kamal_hetzner"

module Rbrun
  # The server provider family. Pure Ruby; depends on no other rbrun gem. Provisions a server and deploys
  # an app onto it — kamal_hetzner today, other adapters later, with no caller change. Resolves the adapter
  # by constant lookup in this namespace (explicit allowlist). The adapter validates its own config.
  module Server
    class Error < StandardError; end

    ADAPTERS = { kamal_hetzner: "KamalHetzner" }.freeze

    def self.new(provider:, config: {}, **opts)
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown server provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(config: config, **opts)
    end
  end
end
```

`gems/rbrun-server/lib/rbrun/server/node.rb`:
```ruby
# frozen_string_literal: true
module Rbrun
  module Server
    # A provisioned server, provider-neutral. Plain value object, no framework.
    Node = Data.define(:id, :name, :ip, :status, :region)
  end
end
```

`gems/rbrun-server/lib/rbrun/server/deploy_result.rb`:
```ruby
# frozen_string_literal: true
module Rbrun
  module Server
    # The outcome of a deploy: ok? + captured output. Plain value object.
    DeployResult = Data.define(:ok, :output)
  end
end
```

`gems/rbrun-server/lib/rbrun/server/base.rb`:
```ruby
# frozen_string_literal: true
module Rbrun
  module Server
    # The interface every server adapter MUST implement. Adapters inherit and override each method; a
    # provider that forgets one fails loud with NotImplementedError. Pure documentation + enforcement.
    # Every mutating method MUST be idempotent by server name (invariant #11).
    class Base
      # Find-or-create the server by name; block until it has a public IP / reaches running. @return [Node]
      def create_server(name:, type:, region:, image:, ssh_keys: [], user_data: nil, labels: {})
        raise NotImplementedError, "#{self.class}#create_server"
      end

      # The server with this name, or nil. @return [Node, nil]
      def find_server(name:)
        raise NotImplementedError, "#{self.class}#find_server"
      end

      # Every server the account owns, optionally narrowed by label. @return [Array<Node>]
      def list_servers(label: nil)
        raise NotImplementedError, "#{self.class}#list_servers"
      end

      # Destroy the server by name. True if one was deleted, false if there was nothing to delete.
      # @return [Boolean]
      def destroy_server(name:)
        raise NotImplementedError, "#{self.class}#destroy_server"
      end

      # Deploy the app in work_dir onto the server via Kamal (local builder). @return [DeployResult]
      def deploy(work_dir:, host:, server_ip:, env: {})
        raise NotImplementedError, "#{self.class}#deploy"
      end
    end
  end
end
```

`gems/rbrun-server/rbrun-server.gemspec`:
```ruby
require_relative "lib/rbrun/server/version"

Gem::Specification.new do |spec|
  spec.name        = "rbrun-server"
  spec.version     = Rbrun::Server::VERSION
  spec.authors     = [ "rbdotrun" ]
  spec.summary     = "Server providers for rbrun (kamal_hetzner) behind one provision/deploy contract."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "async", ">= 2.0"
  spec.add_dependency "async-http", ">= 0.60"
  spec.add_dependency "async-http-faraday", ">= 0.12"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "kamal", ">= 2.0"

  spec.add_development_dependency "webmock", "~> 3.0"
end
```

`gems/rbrun-server/Rakefile`:
```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
```

`gems/rbrun-server/README.md`:
```markdown
# rbrun-server

Server providers for rbrun behind one provision/deploy contract (`Rbrun::Server::Base`). `kamal_hetzner`
today: provision on Hetzner Cloud (HTTP API), deploy via Kamal's local builder.
```

Note: `lib/rbrun/server.rb` requires `kamal_hetzner` (built in Task 2). Until then, stub it or reorder — build Task 2 in the same PR so the require resolves. To keep Task 1 independently green, temporarily comment the `require "rbrun/server/kamal_hetzner"` line and the `KamalHetzner`-dependent test, then restore in Task 2.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd gems/rbrun-server && bundle exec rake test`
Expected: PASS (with the KamalHetzner require/test temporarily deferred to Task 2).

- [ ] **Step 5: Commit**
```bash
git add gems/rbrun-server
git commit -m "feat(server): rbrun-server gem — :server family, Base interface, value objects"
```

---

### Task 2: `KamalHetzner` provisioning — Hetzner Cloud API over Faraday/async-http

**Files:**
- Create: `gems/rbrun-server/lib/rbrun/server/kamal_hetzner.rb`
- Test: `gems/rbrun-server/test/rbrun/server/kamal_hetzner_test.rb`

**Interfaces:**
- Consumes: `Rbrun::Server::Base`, `Node`, `Error` (Task 1).
- Produces: `Rbrun::Server::KamalHetzner < Base` implementing `create_server`/`find_server`/`list_servers`/`destroy_server`; validated config `{ hcloud_token:, ssh_public_key:, ssh_private_key:, registry: {…} }`; `poll_interval:` (default `2`, `0` in tests) and `poll_attempts:` (default `60`) init kwargs.

- [ ] **Step 1: Write the failing test**

`gems/rbrun-server/test/rbrun/server/kamal_hetzner_test.rb`:
```ruby
# frozen_string_literal: true
require "test_helper"

class KamalHetznerTest < Minitest::Test
  API = "https://api.hetzner.cloud/v1"
  CFG = { hcloud_token: "tok", ssh_public_key: "ssh-rsa k", ssh_private_key: "priv",
          registry: { server: "docker.io", username: "u", password: "pw" } }.freeze

  def adapter = Rbrun::Server::KamalHetzner.new(config: CFG, poll_interval: 0, poll_attempts: 3)

  def test_missing_token_fails_fast
    error = assert_raises(Rbrun::Server::Error) { Rbrun::Server::KamalHetzner.new(config: CFG.merge(hcloud_token: "")) }
    assert_match(/hcloud_token/, error.message)
  end

  def test_create_server_is_idempotent_returns_existing
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-1" })
      .to_return(status: 200, body: { servers: [ { id: 9, name: "w-1", status: "running",
        public_net: { ipv4: { ip: "5.6.7.8" } }, datacenter: { location: { name: "fsn1" } } } ] }.to_json,
        headers: { "Content-Type" => "application/json" })

    node = adapter.create_server(name: "w-1", type: "cx23", region: "fsn1", image: "ubuntu-24.04")
    assert_equal "5.6.7.8", node.ip
    assert_equal "running", node.status
  end

  def test_create_server_posts_then_polls_until_running
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-2" })
      .to_return(status: 200, body: { servers: [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, "#{API}/servers")
      .to_return(status: 201, body: { server: { id: 10, name: "w-2", status: "initializing",
        public_net: { ipv4: { ip: nil } } } }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{API}/servers/10")
      .to_return({ status: 200, body: { server: { id: 10, name: "w-2", status: "initializing",
        public_net: { ipv4: { ip: nil } } } }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { server: { id: 10, name: "w-2", status: "running",
        public_net: { ipv4: { ip: "1.1.1.1" } }, datacenter: { location: { name: "fsn1" } } } }.to_json,
        headers: { "Content-Type" => "application/json" } })

    node = adapter.create_server(name: "w-2", type: "cx23", region: "fsn1", image: "ubuntu-24.04")
    assert_equal "1.1.1.1", node.ip
  end

  def test_destroy_server_is_noop_when_absent
    stub_request(:get, "#{API}/servers").with(query: { "name" => "gone" })
      .to_return(status: 200, body: { servers: [] }.to_json, headers: { "Content-Type" => "application/json" })
    refute adapter.destroy_server(name: "gone")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd gems/rbrun-server && bundle exec rake test`
Expected: FAIL — `uninitialized constant Rbrun::Server::KamalHetzner`.

- [ ] **Step 3: Write the adapter**

`gems/rbrun-server/lib/rbrun/server/kamal_hetzner.rb`:
```ruby
# frozen_string_literal: true
require "json"
require "faraday"
require "async/http/faraday"

module Rbrun
  module Server
    # Hetzner Cloud provisioning + Kamal deploy. FARADAY ON ASYNC-HTTP (fork-safe under Falcon), built from
    # EXPLICIT credentials, never the environment. Validates its own config, fails fast. create/destroy are
    # idempotent by server name so re-running converges (invariant #11). Never uses the hcloud CLI.
    class KamalHetzner < Base
      API = "https://api.hetzner.cloud/v1"

      def initialize(config: {}, poll_interval: 2, poll_attempts: 60)
        @token   = config[:hcloud_token]
        @ssh_pub = config[:ssh_public_key]
        @ssh_key = config[:ssh_private_key]
        @registry = config[:registry] || {}
        @poll_interval = poll_interval
        @poll_attempts = poll_attempts
        raise Error, "kamal_hetzner: hcloud_token missing" if @token.to_s.empty?
        raise Error, "kamal_hetzner: ssh_private_key missing" if @ssh_key.to_s.empty?
      end

      def find_server(name:)
        node_from(Array(request(:get, "/servers", nil, { "name" => name })["servers"]).first)
      end

      def list_servers(label: nil)
        params = {}
        params["label_selector"] = label if label
        Array(request(:get, "/servers", nil, params)["servers"]).map { |s| node_from(s) }
      end

      def create_server(name:, type:, region:, image:, ssh_keys: [], user_data: nil, labels: {})
        existing = find_server(name: name)
        return await_ready(existing) if existing

        body = { "name" => name, "server_type" => type, "image" => image, "location" => region,
                 "ssh_keys" => (ssh_keys.presence || default_ssh_keys), "labels" => labels }
        body["user_data"] = user_data if user_data
        created = node_from(request(:post, "/servers", body).fetch("server"))
        await_ready(created)
      end

      def destroy_server(name:)
        existing = find_server(name: name)
        return false unless existing

        request(:delete, "/servers/#{existing.id}")
        true
      end

      private

      # The account's ssh key names to attach — we register ours by fingerprint elsewhere; here we pass the
      # public key inline via a stable name derived from the key so Hetzner de-dups.
      def default_ssh_keys = [] # populated by the engine tool when it manages the key; empty is valid.

      def await_ready(node)
        attempts = 0
        while node && (node.status != "running" || node.ip.to_s.empty?)
          attempts += 1
          break if attempts > @poll_attempts

          sleep @poll_interval if @poll_interval.positive?
          node = node_from(request(:get, "/servers/#{node.id}").fetch("server"))
        end
        node
      end

      def node_from(raw)
        return nil unless raw

        Node.new(id: raw["id"], name: raw["name"], status: raw["status"],
                 ip: raw.dig("public_net", "ipv4", "ip"),
                 region: raw.dig("datacenter", "location", "name"))
      end

      def request(method, path, body = nil, params = {})
        response = conn.public_send(method, "#{API}#{path}") do |req|
          req.params.update(params) if params.any?
          next if body.nil?

          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        parsed = response.body.is_a?(Hash) ? response.body : (JSON.parse(response.body.to_s) rescue {})
        return parsed if response.success?

        msg = parsed.dig("error", "message") || response.status
        raise Error, "kamal_hetzner: #{method.to_s.upcase} #{path} → #{response.status} #{msg}"
      end

      def conn
        @conn ||= Faraday.new do |f|
          f.response :json, content_type: /\bjson/
          f.headers["Authorization"] = "Bearer #{@token}"
          f.options.open_timeout = 15
          f.options.timeout = 30
          f.adapter :async_http
        end
      end
    end
  end
end
```

Note: `.presence` is ActiveSupport; the gem is pure — replace with `(ssh_keys.empty? ? default_ssh_keys : ssh_keys)`. Restore the `require "rbrun/server/kamal_hetzner"` line + the KamalHetzner test deferred in Task 1.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd gems/rbrun-server && bundle exec rake test`
Expected: PASS (all of Task 1 + Task 2).

- [ ] **Step 5: Commit**
```bash
git add gems/rbrun-server
git commit -m "feat(server): KamalHetzner provisioning via Hetzner Cloud API (Faraday/async-http)"
```

---

### Task 3: `KamalHetzner#deploy` — Kamal local builder

**Files:**
- Modify: `gems/rbrun-server/lib/rbrun/server/kamal_hetzner.rb`
- Test: `gems/rbrun-server/test/rbrun/server/kamal_hetzner_test.rb` (add cases)

**Interfaces:**
- Produces: `KamalHetzner#deploy(work_dir:, host:, server_ip:, env: {})` → `DeployResult`, shelling `kamal deploy` in `work_dir` with registry creds + `KAMAL_HOST`/`KAMAL_SERVER_IP` in the child env. Uses a private `run_kamal(argv, env:, chdir:)` (Open3) that tests stub.

- [ ] **Step 1: Write the failing test** (add to `kamal_hetzner_test.rb`)
```ruby
  def test_deploy_shells_kamal_with_registry_and_server_ip
    captured = {}
    adp = adapter
    adp.define_singleton_method(:run_kamal) do |argv, env:, chdir:|
      captured[:argv] = argv; captured[:env] = env; captured[:chdir] = chdir
      [ "Deployed w-1", true ]
    end

    result = adp.deploy(work_dir: "/work/w-1", host: "w1.rb.run", server_ip: "1.1.1.1")
    assert result.ok
    assert_equal "/work/w-1", captured[:chdir]
    assert_includes captured[:argv], "deploy"
    assert_equal "pw", captured[:env]["KAMAL_REGISTRY_PASSWORD"]
    assert_equal "1.1.1.1", captured[:env]["KAMAL_SERVER_IP"]
    assert_equal "w1.rb.run", captured[:env]["KAMAL_HOST"]
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd gems/rbrun-server && bundle exec rake test -n /deploy/`
Expected: FAIL — `NoMethodError: undefined method 'deploy'` (Base raises / not overridden).

- [ ] **Step 3: Implement `deploy` + `run_kamal`** (add to `KamalHetzner`, before `private` for `deploy`)
```ruby
      def deploy(work_dir:, host:, server_ip:, env: {})
        child_env = {
          "KAMAL_REGISTRY_PASSWORD" => @registry[:password].to_s,
          "KAMAL_REGISTRY_USERNAME" => @registry[:username].to_s,
          "KAMAL_HOST"              => host.to_s,
          "KAMAL_SERVER_IP"         => server_ip.to_s,
        }.merge(env.transform_keys(&:to_s))
        output, ok = run_kamal([ "deploy" ], env: child_env, chdir: work_dir)
        DeployResult.new(ok: ok, output: output)
      end
```
And under `private`:
```ruby
      require "open3"
      def run_kamal(argv, env:, chdir:)
        out, status = Open3.capture2e(env, "kamal", *argv, chdir: chdir)
        [ out, status.success? ]
      end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cd gems/rbrun-server && bundle exec rake test`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add gems/rbrun-server
git commit -m "feat(server): KamalHetzner#deploy — kamal local builder with registry + server ip"
```

---

### Task 4: Engine composition root — `Rbrun.server`

**Files:**
- Modify: `lib/rbrun.rb`
- Test: `test/rbrun/server_constructor_test.rb`

**Interfaces:**
- Consumes: `Rbrun.build`, `config(tenant).server_provider` (already exists), `Rbrun::Server` (Task 1).
- Produces: `Rbrun.server(provider = nil, tenant: nil, **opts)` → adapter for the configured provider.

- [ ] **Step 1: Write the failing test**

`test/rbrun/server_constructor_test.rb`:
```ruby
# frozen_string_literal: true
require "test_helper"

class ServerConstructorTest < ActiveSupport::TestCase
  test "Rbrun.server builds the configured adapter" do
    Rbrun.configure do |c|
      c.server_provider = { default: :kamal_hetzner,
                            kamal_hetzner: { hcloud_token: "t", ssh_public_key: "k", ssh_private_key: "p",
                                             registry: { server: "docker.io", username: "u", password: "pw" } } }
    end
    assert_instance_of Rbrun::Server::KamalHetzner, Rbrun.server
  ensure
    Rbrun.reset_config!
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/rbrun/server_constructor_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'server' for Rbrun`.

- [ ] **Step 3: Add the constructor** — in `lib/rbrun.rb`, after `dns`:
```ruby
    def server(provider = nil, tenant: nil, **opts)
      require "rbrun/server"
      build(Rbrun::Server, config(tenant).server_provider, provider: provider, **opts)
    end
```

- [ ] **Step 4: Run the test and make sure it passes**

Run: `bin/rails test test/rbrun/server_constructor_test.rb`
Expected: PASS. (The `Gemfile` already globs `gems/*/*.gemspec`, so `rbrun-server` is picked up; run `bundle install` first if needed.)

- [ ] **Step 5: Commit**
```bash
git add lib/rbrun.rb test/rbrun/server_constructor_test.rb Gemfile.lock
git commit -m "feat(server): Rbrun.server composition root"
```

---

### Task 5: `Rbrun::DeployTarget` model — `has_one` per `Worktree`

**Files:**
- Create: `db/migrate/20260721120000_create_rbrun_deploy_targets.rb`
- Create: `app/models/rbrun/deploy_target.rb`
- Modify: `app/models/rbrun/worktree.rb` (add `has_one :deploy_target`)
- Test: `test/models/rbrun/deploy_target_test.rb`

**Interfaces:**
- Produces: `Rbrun::DeployTarget` (`belongs_to :worktree`, Tenanted, unique per worktree); `Worktree#deploy_target` / `Worktree#create_deploy_target!`. Columns: `provider, server_type, region, image, host, server_id, server_ip, status`.

- [ ] **Step 1: Write the failing test**

`test/models/rbrun/deploy_target_test.rb`:
```ruby
# frozen_string_literal: true
require "test_helper"

class DeployTargetTest < ActiveSupport::TestCase
  setup { @worktree = rbrun_worktrees(:one) } # existing fixture; or Worktree.create! per test conventions

  test "inherits the worktree's tenant" do
    dt = @worktree.create_deploy_target!(provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                         image: "ubuntu-24.04", host: "w1.rb.run", status: "pending")
    assert_equal @worktree.tenant, dt.public_send(Rbrun.config.tenancy_key)
  end

  test "one target per worktree" do
    @worktree.create_deploy_target!(provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                    image: "ubuntu-24.04", host: "w1.rb.run", status: "pending")
    assert_raises(ActiveRecord::RecordNotUnique) do
      Rbrun::DeployTarget.create!(worktree: @worktree, provider: "kamal_hetzner", server_type: "cx23",
                                  region: "fsn1", image: "ubuntu-24.04", host: "dup.rb.run", status: "pending")
    end
  end
end
```
(Match the repo's existing worktree test setup — reuse whatever `ServiceExposure`/`Worktree` tests use to obtain a persisted worktree.)

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/models/rbrun/deploy_target_test.rb`
Expected: FAIL — `uninitialized constant Rbrun::DeployTarget`.

- [ ] **Step 3: Migration + model + association**

`db/migrate/20260721120000_create_rbrun_deploy_targets.rb`:
```ruby
class CreateRbrunDeployTargets < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_deploy_targets do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string Rbrun.config.tenancy_key, null: false
      t.string :provider,    null: false
      t.string :server_type, null: false
      t.string :region,      null: false
      t.string :image,       null: false
      t.string :host,        null: false
      t.string :server_id
      t.string :server_ip
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
    add_index :rbrun_deploy_targets, :worktree_id, unique: true
  end
end
```

`app/models/rbrun/deploy_target.rb`:
```ruby
module Rbrun
  # The worktree's deployment: which server (Hetzner) the app is deployed onto and at which DNS host. One
  # per worktree (mirrors ServiceExposure's per-[worktree] grain). Tenant is inherited from the worktree.
  class DeployTarget < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create

    STATUSES = %w[pending provisioned deployed torn_down].freeze
    validates :provider, :server_type, :region, :image, :host, presence: true
    validates :status, inclusion: { in: STATUSES }

    private

    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
  end
end
```

`app/models/rbrun/worktree.rb` — add after the `has_many` block:
```ruby
    has_one :deploy_target, class_name: "Rbrun::DeployTarget", dependent: :destroy
```

- [ ] **Step 4: Migrate + run the tests**

Run: `bin/rails db:test:prepare && bin/rails test test/models/rbrun/deploy_target_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add db/migrate app/models/rbrun/deploy_target.rb app/models/rbrun/worktree.rb test/models/rbrun/deploy_target_test.rb db/schema.rb
git commit -m "feat(server): Rbrun::DeployTarget — one per worktree, tenant-inherited"
```

---

### Task 6: Deploy tools — provision → dns → prepare → deploy → teardown

**Files:**
- Create: `app/tools/rbrun/tools/deploy_status.rb`
- Create: `app/tools/rbrun/tools/provision_server.rb`
- Create: `app/tools/rbrun/tools/create_deploy_dns.rb`
- Create: `app/tools/rbrun/tools/prepare_deploy.rb`
- Create: `app/tools/rbrun/tools/deploy.rb`
- Create: `app/tools/rbrun/tools/teardown_deploy.rb`
- Modify: `lib/rbrun/engine.rb` (register the six)
- Test: `test/tools/rbrun/deploy_tools_test.rb`

**Interfaces:**
- Consumes: `session.worktree`, `Worktree#deploy_target`, `Rbrun.server`, `Rbrun.dns`, `Rbrun::Server::Node`.
- Produces: six `Rbrun::Tools::*` tools; `deploy` is `needs_approval!`. Each returns `{ "data" => {…} }` or `error(...)`. The server name is worktree-derived: `"rbrun-w#{worktree.id}"`; the label `{ "rbrun-worktree" => worktree.id.to_s }`.

- [ ] **Step 1: Write the failing test**

`test/tools/rbrun/deploy_tools_test.rb`:
```ruby
# frozen_string_literal: true
require "test_helper"

class DeployToolsTest < ActiveSupport::TestCase
  setup do
    @session  = # build a persisted Session with a Worktree, per existing tool-test conventions
    @worktree = @session.worktree
    @fake_server = Minitest::Mock.new
    @fake_dns    = Minitest::Mock.new
    Rbrun.stub(:server, @fake_server) { Rbrun.stub(:dns, @fake_dns) { yield_examples } }
  end

  def yield_examples; end # placeholder — inline the stubs per test below

  test "provision_server creates the box and records the ip on the worktree target" do
    node = Rbrun::Server::Node.new(id: 42, name: "rbrun-w#{@worktree.id}", ip: "9.9.9.9", status: "running", region: "fsn1")
    @fake_server.expect(:create_server, node, [], name: "rbrun-w#{@worktree.id}", type: String, region: String, image: String, labels: Hash)
    Rbrun.stub(:server, @fake_server) do
      result = Rbrun::Tools::ProvisionServer.in_session(@session).execute
      assert_equal "9.9.9.9", result.dig("data", "server_ip")
    end
    assert_equal "9.9.9.9", @worktree.reload.deploy_target.server_ip
    @fake_server.verify
  end

  test "deploy is gated" do
    assert Rbrun::Tools::Deploy.needs_approval?
  end

  test "teardown destroys server and removes dns" do
    @worktree.create_deploy_target!(provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                    image: "ubuntu-24.04", host: "w.rb.run", server_ip: "9.9.9.9", status: "deployed")
    @fake_server.expect(:destroy_server, true, [], name: "rbrun-w#{@worktree.id}")
    @fake_dns.expect(:remove, true, [], name: "w.rb.run", type: "A")
    Rbrun.stub(:server, @fake_server) do
      Rbrun.stub(:dns, @fake_dns) do
        Rbrun::Tools::TeardownDeploy.in_session(@session).execute
      end
    end
    assert_equal "torn_down", @worktree.reload.deploy_target.status
    @fake_server.verify; @fake_dns.verify
  end
end
```
(Adapt session/worktree construction to the repo's existing tool-test helpers.)

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/tools/rbrun/deploy_tools_test.rb`
Expected: FAIL — `uninitialized constant Rbrun::Tools::ProvisionServer`.

- [ ] **Step 3: Write the tools**

`app/tools/rbrun/tools/provision_server.rb`:
```ruby
module Rbrun
  module Tools
    # Find-or-create the Hetzner server for this worktree and record its IP on the worktree's deploy target.
    # Idempotent: the server name is worktree-derived, so re-running returns the same box (invariant #11).
    class ProvisionServer < Rbrun::ApplicationTool
      description "Provision (find-or-create) the cloud server for this worktree's deployment and record its IP. Idempotent."

      def execute
        wt = session.worktree
        target = wt.deploy_target || wt.create_deploy_target!(default_attrs(wt))
        node = Rbrun.server(tenant: session.tenant).create_server(
          name: server_name(wt), type: target.server_type, region: target.region,
          image: target.image, labels: { "rbrun-worktree" => wt.id.to_s })
        target.update!(server_id: node.id.to_s, server_ip: node.ip, status: "provisioned")
        { "data" => { "server_ip" => node.ip, "status" => node.status } }
      end

      private

      def server_name(wt) = "rbrun-w#{wt.id}"

      def default_attrs(wt)
        { provider: "kamal_hetzner", server_type: "cx23", region: "fsn1", image: "ubuntu-24.04",
          host: "#{server_name(wt)}.#{Rbrun.config.preview_domain}", status: "pending" }
      end
    end
  end
end
```

`app/tools/rbrun/tools/create_deploy_dns.rb`:
```ruby
module Rbrun
  module Tools
    # Point this worktree's deploy host at the provisioned server IP (A record, via the :dns family).
    class CreateDeployDns < Rbrun::ApplicationTool
      description "Create/update the DNS A record for this worktree's deploy host, pointing at the provisioned server IP."

      def execute
        target = session.worktree.deploy_target
        return error("no server provisioned yet — run provision_server first") if target.nil? || target.server_ip.blank?

        rec = Rbrun.dns(tenant: session.tenant).upsert(name: target.host, type: "A", content: target.server_ip)
        { "data" => { "host" => rec.name, "ip" => rec.content } }
      end
    end
  end
end
```

`app/tools/rbrun/tools/prepare_deploy.rb`:
```ruby
module Rbrun
  module Tools
    # Scaffold the deploy setup (Dockerfile + config/deploy.yml) into the worktree, rendered from the
    # preview-deploy skill's templates with this target's host + registry. Idempotent file upsert.
    class PrepareDeploy < Rbrun::ApplicationTool
      description "Write Dockerfile + config/deploy.yml into the worktree for Kamal deploy (from the preview-deploy skill templates)."

      def execute
        target = session.worktree.deploy_target
        return error("no deploy target — run provision_server first") if target.nil?

        written = Rbrun::DeployScaffold.new(session.worktree, target).write! # sandbox file writes
        { "data" => { "written" => written } }
      end
    end
  end
end
```
(`Rbrun::DeployScaffold` is a thin service writing the two files into the worktree's sandbox using the skill's `examples/`. Keep it small; render `deploy.yml` with `service`, `image` = `#{registry}/rbrun-w<id>`, `servers: ["<%= ENV['KAMAL_SERVER_IP'] %>"]`, `proxy.host` = target.host, `builder: { arch: amd64 }`.)

`app/tools/rbrun/tools/deploy.rb`:
```ruby
module Rbrun
  module Tools
    # Deploy the worktree's app onto its server via Kamal (local builder). GATED — a deploy makes the app
    # publicly reachable, which is a human decision (invariant #10).
    class Deploy < Rbrun::ApplicationTool
      description "Deploy this worktree's app to its provisioned server via Kamal (local builder). Requires approval."
      needs_approval!

      def execute
        target = session.worktree.deploy_target
        return error("no server provisioned") if target.nil? || target.server_ip.blank?

        result = Rbrun.server(tenant: session.tenant).deploy(
          work_dir: session.worktree.checkout_path, host: target.host, server_ip: target.server_ip)
        target.update!(status: "deployed") if result.ok
        { "data" => { "ok" => result.ok, "output" => result.output.to_s.last(2000) } }
      end
    end
  end
end
```
(Use whatever the repo calls the local worktree checkout path; if the deploy runs in the sandbox, thread the sandbox working dir instead.)

`app/tools/rbrun/tools/teardown_deploy.rb`:
```ruby
module Rbrun
  module Tools
    # Reap this worktree's deployment: destroy the server AND remove its DNS record, then mark the target
    # torn_down. Idempotent — safe to re-run (invariant #11).
    class TeardownDeploy < Rbrun::ApplicationTool
      description "Tear down this worktree's deployment: destroy the server and remove its DNS record."

      def execute
        wt = session.worktree
        target = wt.deploy_target
        return { "data" => { "torn_down" => true, "noop" => true } } if target.nil?

        Rbrun.server(tenant: session.tenant).destroy_server(name: "rbrun-w#{wt.id}")
        Rbrun.dns(tenant: session.tenant).remove(name: target.host, type: "A")
        target.update!(status: "torn_down", server_id: nil, server_ip: nil)
        { "data" => { "torn_down" => true } }
      end
    end
  end
end
```

`app/tools/rbrun/tools/deploy_status.rb`:
```ruby
module Rbrun
  module Tools
    # Read-only: the worktree's deploy target (server + host + status).
    class DeployStatus < Rbrun::ApplicationTool
      description "Show this worktree's deployment status: server IP, DNS host, and lifecycle status."

      def execute
        t = session.worktree.deploy_target
        return { "data" => { "status" => "none" } } if t.nil?

        { "data" => { "status" => t.status, "host" => t.host, "server_ip" => t.server_ip } }
      end
    end
  end
end
```

Register in `lib/rbrun/engine.rb` (after the repo-services block):
```ruby
      [ Rbrun::Tools::DeployStatus, Rbrun::Tools::ProvisionServer, Rbrun::Tools::CreateDeployDns,
        Rbrun::Tools::PrepareDeploy, Rbrun::Tools::Deploy, Rbrun::Tools::TeardownDeploy
      ].each { |t| Rbrun.register_tool(t) }
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `bin/rails test test/tools/rbrun/deploy_tools_test.rb`
Expected: PASS. Then full: `bin/rails test`.

- [ ] **Step 5: Commit**
```bash
git add app/tools/rbrun/tools lib/rbrun/engine.rb test/tools/rbrun/deploy_tools_test.rb
git commit -m "feat(server): worktree-scoped deploy tools (provision/dns/prepare/deploy(gated)/teardown/status)"
```

---

### Task 7: `preview-deploy` skill — curated Dockerfiles + Kamal template

**Files:**
- Create: `app/skills/preview-deploy/SKILL.md`
- Create: `app/skills/preview-deploy/examples/Dockerfile.rails`
- Create: `app/skills/preview-deploy/examples/Dockerfile.node`
- Create: `app/skills/preview-deploy/examples/deploy.yml`
- Test: `test/services/rbrun/skill_seeder_preview_deploy_test.rb`

**Interfaces:**
- Consumes: `Rbrun::SkillSeeder` (`BUILTIN_DIR = app/skills`), the tools from Task 6.
- Produces: a seedable skill slug `preview-deploy` that materializes into the sandbox on stage.

- [ ] **Step 1: Write the failing test**

`test/services/rbrun/skill_seeder_preview_deploy_test.rb`:
```ruby
# frozen_string_literal: true
require "test_helper"

class SkillSeederPreviewDeployTest < ActiveSupport::TestCase
  test "preview-deploy skill source exists and seeds" do
    dir = Rbrun::Engine.root.join("app/skills/preview-deploy")
    assert dir.join("SKILL.md").exist?
    assert dir.join("examples/deploy.yml").exist?
    # seeding for the default tenant creates a Skill for the slug (match existing seeder test conventions)
    Rbrun::SkillSeeder.seed!(tenant: Rbrun.config.default_tenant) if Rbrun::SkillSeeder.respond_to?(:seed!)
    assert Rbrun::Skill.where(slug: "preview-deploy").exists?
  end
end
```
(Adapt to the seeder's real API from `app/services/rbrun/skill_seeder.rb`.)

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/rbrun/skill_seeder_preview_deploy_test.rb`
Expected: FAIL — the skill directory does not exist.

- [ ] **Step 3: Author the skill**

`app/skills/preview-deploy/SKILL.md`:
```markdown
# preview-deploy

Deploy this worktree's app to a public URL. Use when the user asks to "deploy", "publish", or "share a live
preview" of the code in this worktree.

## Lifecycle (each step is a tool; all idempotent)

1. `provision_server` — find-or-create the worktree's server, record its IP.
2. `create_deploy_dns` — point the deploy host at that IP.
3. `prepare_deploy` — write Dockerfile + config/deploy.yml (adapt the examples below to the stack).
4. `deploy` — Kamal deploy (local builder). **This is gated — the user approves it.**
5. `teardown_deploy` — when done, destroy the server + DNS. Never leave infra running.

## Dockerfiles

Pick and adapt `examples/Dockerfile.rails` or `examples/Dockerfile.node`. Keep the image slim, expose the
app port, and honour Kamal's healthcheck path.
```

`app/skills/preview-deploy/examples/deploy.yml`:
```yaml
service: <%= service %>
image: <%= image %>
servers:
  web:
    - <%= "<%= ENV['KAMAL_SERVER_IP'] %>" %>
proxy:
  ssl: true
  host: <%= host %>
builder:
  arch: amd64            # local builder
registry:
  server: <%= registry_server %>
  username:
    - KAMAL_REGISTRY_USERNAME
  password:
    - KAMAL_REGISTRY_PASSWORD
```
(Plus the two `Dockerfile.*` examples — a standard Rails slim image and a Node image; keep them minimal and curated.)

- [ ] **Step 4: Run the test and make sure it passes**

Run: `bin/rails test test/services/rbrun/skill_seeder_preview_deploy_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**
```bash
git add app/skills/preview-deploy test/services/rbrun/skill_seeder_preview_deploy_test.rb
git commit -m "feat(server): preview-deploy skill — curated Dockerfiles + Kamal template"
```

---

### Task 8: Dogfood — one real provision → dns → deploy, PROVE the live URL (no reap)

**Files:**
- Create: `lib/tasks/rbrun/dogfood/server_deploy.rake`

**Interfaces:**
- Consumes: `Rbrun.server`, `Rbrun.dns`, the tools, `Rbrun::Dogfood` helpers (`support.rb`).
- Produces: `app:dogfood:server_deploy` — drives ONE real deploy end-to-end and **prints the live URL**.

> **Deliberate override (user-directed):** this proving dogfood does **NOT** reap. The goal is a clickable
> live URL handed back as proof; tearing down would erase the proof. Teardown is validated **separately**
> (Task 8b) once the URL is confirmed. This is a scoped exception to the reap-in-`ensure` default — the
> reaping path still exists as `teardown_deploy` (Task 6) and Task 8b. `ensure` here only cleans up on
> *failure*, never on success.

- [ ] **Step 1: Write the dogfood scenario** (no unit test — dogfood is the gate, invariant #6)

`lib/tasks/rbrun/dogfood/server_deploy.rake`:
```ruby
# One real deploy lifecycle against real Hetzner + Cloudflare. On SUCCESS it leaves the deployment UP and
# prints the live URL — that clickable URL is the proof (user-directed; do not reap on success). Only a
# FAILURE reaps, so a broken run leaves nothing behind. Never variabilized (invariant #6).
namespace :dogfood do
  task server_deploy: :environment do
    include Rbrun::Dogfood
    header "server deploy — provision → dns → prepare → deploy → PROVE url"
    name = "rbrun-dogfood"
    host = "dogfood.#{Rbrun.config.preview_domain}"
    wt = # create/lookup a dogfood worktree per support.rb conventions
    deployed = false
    begin
      node = Rbrun.server.create_server(name: name, type: "cx23", region: "fsn1", image: "ubuntu-24.04",
                                        labels: { "rbrun-dogfood" => "1" })
      ok "server running with ip #{node.ip}" if node.ip
      rec = Rbrun.dns.upsert(name: host, type: "A", content: node.ip)
      ok "dns #{rec.name} -> #{rec.content}"
      # prepare + deploy the worktree's app via the tools (Kamal local builder), then poll the host until
      # it answers 200 over HTTPS.
      # ... prepare_deploy + deploy here ...
      deployed = true
      ok "LIVE: https://#{host}"   # <- the hand-off proof
      info "left UP on purpose — validate teardown separately with app:dogfood:server_teardown"
    rescue => e
      # failure path only: reap so a broken run leaves nothing behind
      Rbrun.server.destroy_server(name: name)
      Rbrun.dns.remove(name: host, type: "A")
      raise e
    end
  end
end
```

- [ ] **Step 2: Run it (real infra)**

Run: `bin/rails app:dogfood:server_deploy`
Expected: `✓ server running…`, `✓ dns …`, deploy signal, `✓ LIVE: https://dogfood.<domain>`. Open the URL — it must serve the app. The deployment stays up.

- [ ] **Step 3: Commit**
```bash
git add lib/tasks/rbrun/dogfood/server_deploy.rake
git commit -m "feat(server): dogfood — real provision/dns/deploy, prove the live URL (no reap on success)"
```

---

### Task 8b: Teardown validation (run AFTER the URL is confirmed)

**Files:**
- Create: `lib/tasks/rbrun/dogfood/server_teardown.rake`

**Interfaces:**
- Produces: `app:dogfood:server_teardown` — destroys the dogfood server + DNS (the reaping path), so we
  validate teardown as its own step once the goal is proven.

- [ ] **Step 1: Write it**

`lib/tasks/rbrun/dogfood/server_teardown.rake`:
```ruby
# Validate teardown — run ONLY after app:dogfood:server_deploy proved the live URL. Destroys the server +
# DNS and confirms both are gone (idempotent, invariant #11).
namespace :dogfood do
  task server_teardown: :environment do
    include Rbrun::Dogfood
    header "server teardown — reap the dogfood deployment"
    name = "rbrun-dogfood"
    host = "dogfood.#{Rbrun.config.preview_domain}"
    Rbrun.server.destroy_server(name: name)
    Rbrun.dns.remove(name: host, type: "A")
    ok "server gone: #{Rbrun.server.find_server(name: name).nil?}"
    info "reaped #{name} + #{host}"
  end
end
```

- [ ] **Step 2: Run it** — Run: `bin/rails app:dogfood:server_teardown`; Expected: `✓ server gone: true`.

- [ ] **Step 3: Commit**
```bash
git add lib/tasks/rbrun/dogfood/server_teardown.rake
git commit -m "feat(server): dogfood — teardown validation (reap the proven deployment)"
```

---

## Self-Review

- **Spec coverage:** gem + Base (T1), provisioning (T2), deploy (T3), composition root (T4), DeployTarget 1:1 (T5), six tools incl. gated deploy (T6), skill (T7), URL-proving dogfood — no reap on success (T8), teardown validation (T8b). All spec §2–§8 covered.
- **Invariants:** no registry (T1 constant lookup), engine composition root + fail-fast config (T2/T4), Faraday async-http (T2), own-DB tenancy (T5), RubyLLM engine-only (T6 tools), deploy gated (T6), idempotency + reap (T2/T6/T8).
- **Type consistency:** `Node(id,name,ip,status,region)` and `DeployResult(ok,output)` used identically across T1–T3, T6, T8; `create_server`/`deploy` signatures match Base ↔ adapter ↔ tools.
- **Adapt-to-repo flags:** session/worktree construction in tests (T5/T6), the worktree checkout/sandbox working dir for deploy (T6), and the seeder API (T7) must be matched to existing conventions during execution — noted inline at each.
