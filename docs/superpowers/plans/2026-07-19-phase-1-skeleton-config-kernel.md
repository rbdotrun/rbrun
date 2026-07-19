# Phase 1 — Skeleton + Config Kernel + Dogfood Spine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the monorepo skeleton and the engine's configuration kernel — `Rbrun.configure`, the `<family>_provider` config convention, the config-aware constructor (`Rbrun.build`), and the dogfood spine — with nothing backend-runnable yet.

**Architecture:** `rbrun` is a mountable Rails engine (already scaffolded) that will path-depend on pure-Ruby provider sub-gems under `gems/`. Phase 1 builds only the engine-side kernel: a plain `Rbrun::Config` object filled by `Rbrun.configure`, and a generic config-aware constructor `Rbrun.build(family_module, providers_config, provider:)` that selects a provider and hands a pure family module an explicit config hash. The family module (arriving in later phases) resolves the concrete adapter by constant lookup and validates its own config. No registry, nothing self-registers.

**Tech Stack:** Ruby, Rails engine (`>= 8.1.3`), Minitest via `bin/rails test`, ActiveSupport (`String#camelize`).

## Global Constraints

Every task's requirements implicitly include these project-wide rules (verbatim from the spec):

- **No registry, no self-registration.** Providers depend on nothing (the only inter-provider dependency, later, is `rbrun-runtime → rbrun-sandbox`). Resolution is constant lookup inside a family's own namespace; the engine injects config. Nothing registers itself anywhere.
- **Provider config convention:** every provider family is a single hash `c.<family>_provider = { default: :name, name: {…config…}, … }`. `:default` is reserved and can never be a provider name.
- **Pure gems are config-agnostic:** a family's `.new(provider:, config:)` takes an explicit config hash and reads no global state. Only the engine reads `Rbrun.configure`.
- **Tenancy defaults:** `tenancy_key` defaults to `"tenant"` (column name); the default tenant slug **value** is `"rbrun"`.
- **Dogfood:** lives in `lib/tasks/rbrun/dogfood/<scenario>.rake`, **one scenario per file**, plus `lib/tasks/rbrun/dogfood/support.rb`. **Never variabilized** — no ENV, no toggles; each scenario is fixed and deterministic.
- **HTTP invariant (applies when HTTP is introduced, Phase 2+):** every outbound HTTP call uses Faraday on the `async-http` adapter, never Typhoeus/libcurl. (No HTTP in Phase 1.)
- **Rails floor:** `rails >= 8.1.3`.

---

## File Structure

**Created:**
- `lib/rbrun/config.rb` — `Rbrun::Config` (flat knobs, `<family>_provider` hashes, repeatable `c.user`, tenancy) + `Rbrun.configure` / `Rbrun.config` / `Rbrun.reset_config!`.
- `lib/rbrun/resolver.rb` — `Rbrun::ConfigError` + `Rbrun.build(family_module, providers_config, provider:, **opts)` (the config-aware constructor mechanism).
- `lib/tasks/rbrun/dogfood/support.rb` — `Rbrun::Dogfood` output helpers (`ok`, `info`, `header`).
- `lib/tasks/rbrun/dogfood/config.rake` — Phase 1 dogfood scenario (`dogfood:config`).
- `test/rbrun/config_test.rb` — config kernel unit tests.
- `test/rbrun/resolver_test.rb` — `Rbrun.build` unit tests (against an in-test dummy family).
- `gems/.keep` — establish the monorepo sub-gems directory.

**Modified:**
- `lib/rbrun.rb` — require `rbrun/config` and `rbrun/resolver`.
- `Gemfile` — glob path-based sub-gems from `gems/*/*.gemspec` (no-op until gems exist).

---

### Task 1: Configuration object — `Rbrun::Config` + `Rbrun.configure`

**Files:**
- Create: `lib/rbrun/config.rb`
- Modify: `lib/rbrun.rb`
- Test: `test/rbrun/config_test.rb`

**Interfaces:**
- Produces:
  - `Rbrun.config → Rbrun::Config` (memoized singleton)
  - `Rbrun.configure { |c| … } → Rbrun::Config` (yields the singleton, returns it)
  - `Rbrun.reset_config! → Rbrun::Config` (replaces the singleton; used by test `setup`)
  - `Rbrun::Config#database_connection` (default `:rbrun`), `#subprocess_timeout` (default `900`), `#github_pat` (default `nil`), `#tenancy_key` (default `"tenant"`) — all read/write
  - `Rbrun::Config#user(email:, password:, tenant: "rbrun")` — appends; `#users → Array<Hash>`
  - `Rbrun::Config#<family>_provider` / `#<family>_provider=` for `family ∈ {sandbox, runtime, dns, server}` — reader returns `{}` when unset
  - `Rbrun::Config::DEFAULT_TENANT == "rbrun"`

- [ ] **Step 1: Write the failing test**

Create `test/rbrun/config_test.rb`:

```ruby
require "test_helper"

class ConfigTest < ActiveSupport::TestCase
  setup { Rbrun.reset_config! }

  test "sane defaults" do
    c = Rbrun.config
    assert_equal :rbrun, c.database_connection
    assert_equal 900, c.subprocess_timeout
    assert_equal "tenant", c.tenancy_key
    assert_nil c.github_pat
    assert_equal [], c.users
    assert_equal({}, c.sandbox_provider)
    assert_equal({}, c.runtime_provider)
  end

  test "configure yields the config and returns it" do
    returned = Rbrun.configure do |c|
      c.subprocess_timeout = 1200
      c.github_pat = "ghp_x"
    end
    assert_equal 1200, Rbrun.config.subprocess_timeout
    assert_equal "ghp_x", Rbrun.config.github_pat
    assert_same Rbrun.config, returned
  end

  test "c.user appends identities with default tenant rbrun" do
    Rbrun.configure do |c|
      c.user email: "a@x.com", password: "p1"
      c.user email: "b@x.com", password: "p2", tenant: "acme"
    end
    assert_equal(
      [
        { email: "a@x.com", password: "p1", tenant: "rbrun" },
        { email: "b@x.com", password: "p2", tenant: "acme" }
      ],
      Rbrun.config.users
    )
  end

  test "family provider hashes store and read; unset returns {}" do
    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: "k" }, local: {} }
    end
    assert_equal :daytona, Rbrun.config.sandbox_provider[:default]
    assert_equal({ api_key: "k" }, Rbrun.config.sandbox_provider[:daytona])
    assert_equal({}, Rbrun.config.runtime_provider)
  end

  test "reset_config! wipes prior state" do
    Rbrun.configure { |c| c.github_pat = "ghp_x" }
    Rbrun.reset_config!
    assert_nil Rbrun.config.github_pat
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/rbrun/config_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'reset_config!' for Rbrun` (kernel not written yet).

- [ ] **Step 3: Write the config kernel**

Create `lib/rbrun/config.rb`:

```ruby
# frozen_string_literal: true

module Rbrun
  # Boot-time configuration for the engine and its provider families.
  # Filled by the host in one initializer: Rbrun.configure { |c| ... }.
  class Config
    DEFAULT_TENANT = "rbrun"
    FAMILIES = %i[sandbox runtime dns server].freeze

    attr_accessor :database_connection, :subprocess_timeout, :github_pat, :tenancy_key
    attr_reader :users

    def initialize
      @database_connection = :rbrun
      @subprocess_timeout  = 900
      @github_pat          = nil
      @tenancy_key         = "tenant"
      @users               = []
      @providers           = {}
    end

    # Repeatable: append one login identity. Omitted tenant ⇒ DEFAULT_TENANT.
    def user(email:, password:, tenant: DEFAULT_TENANT)
      @users << { email: email, password: password, tenant: tenant }
    end

    FAMILIES.each do |family|
      define_method("#{family}_provider") { @providers[family] || {} }
      define_method("#{family}_provider=") { |hash| @providers[family] = hash }
    end
  end

  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
      config
    end

    def reset_config!
      @config = Config.new
    end
  end
end
```

- [ ] **Step 4: Require the kernel from the entrypoint**

Modify `lib/rbrun.rb` — add the `require` for config immediately after the version require:

```ruby
require "rbrun/version"
require "rbrun/config"
require "rbrun/engine"

module Rbrun
  # Your code goes here...
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/rbrun/config_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/rbrun/config.rb lib/rbrun.rb test/rbrun/config_test.rb
git commit -m "feat(config): Rbrun.configure kernel — flat knobs, users, <family>_provider hashes"
```

---

### Task 2: Config-aware constructor — `Rbrun.build` + `Rbrun::ConfigError`

**Files:**
- Create: `lib/rbrun/resolver.rb`
- Modify: `lib/rbrun.rb`
- Test: `test/rbrun/resolver_test.rb`

**Interfaces:**
- Consumes: `Rbrun::Config` provider hashes from Task 1 (shape `{ default: :name, name: {…} }`).
- Produces:
  - `Rbrun::ConfigError < StandardError`
  - `Rbrun.build(family_module, providers_config, provider: nil, **opts) → Object` — selects a provider (explicit `provider:` or the hash's `:default`), fetches its config sub-hash, and calls `family_module.new(provider: <name>, config: <sub-hash>, **opts)`. Raises `Rbrun::ConfigError` when: `provider:` is `:default`; no provider and no `:default`; or the selected name has no config entry.
  - Contract expected of any `family_module`: it responds to `.new(provider:, config:, **opts)` and resolves/validates internally. (Real families arrive in later phases; tests use an in-file dummy.)

- [ ] **Step 1: Write the failing test**

Create `test/rbrun/resolver_test.rb`:

```ruby
require "test_helper"

# A stand-in for a real provider gem: `.new(provider:)` resolves the adapter by constant lookup;
# the adapter validates the config it is handed (fail-fast). Real gems (rbrun-sandbox, …) do the same.
module ResolverDummy
  def self.new(provider:, config:, **opts)
    const_get(provider.to_s.camelize).new(**config, **opts)
  end

  class Echo
    attr_reader :token

    def initialize(token: nil, **)
      raise Rbrun::ConfigError, "echo requires :token" if token.nil? || token.to_s.empty?
      @token = token
    end
  end
end

class ResolverTest < ActiveSupport::TestCase
  CFG = { default: :echo, echo: { token: "hi" } }.freeze

  test "selects the :default provider and injects its config" do
    obj = Rbrun.build(ResolverDummy, CFG)
    assert_instance_of ResolverDummy::Echo, obj
    assert_equal "hi", obj.token
  end

  test "an explicit provider: overrides the default" do
    obj = Rbrun.build(ResolverDummy, CFG, provider: :echo)
    assert_equal "hi", obj.token
  end

  test "no provider and no :default raises ConfigError" do
    error = assert_raises(Rbrun::ConfigError) { Rbrun.build(ResolverDummy, {}) }
    assert_match(/no provider/i, error.message)
  end

  test "a selected provider with no config entry raises ConfigError" do
    error = assert_raises(Rbrun::ConfigError) { Rbrun.build(ResolverDummy, { default: :echo }) }
    assert_match(/no configuration for provider :echo/i, error.message)
  end

  test ":default is reserved and cannot be selected as a provider" do
    error = assert_raises(Rbrun::ConfigError) { Rbrun.build(ResolverDummy, CFG, provider: :default) }
    assert_match(/reserved/i, error.message)
  end

  test "adapter validates its own config — missing required key fails fast" do
    error = assert_raises(Rbrun::ConfigError) do
      Rbrun.build(ResolverDummy, { default: :echo, echo: {} })
    end
    assert_match(/echo requires :token/i, error.message)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/rbrun/resolver_test.rb`
Expected: FAIL — `NameError: uninitialized constant Rbrun::ConfigError` (resolver not written yet).

- [ ] **Step 3: Write the resolver**

Create `lib/rbrun/resolver.rb`:

```ruby
# frozen_string_literal: true

require "active_support/core_ext/string/inflections" # String#camelize (used by family modules)

module Rbrun
  class ConfigError < StandardError; end

  # The config-aware constructor mechanism shared by every family wrapper (Rbrun.sandbox,
  # Rbrun.runtime, … — added with their gems in later phases). Selects a provider from a
  # `<family>_provider` config hash and hands the pure family module an explicit config hash;
  # the family resolves the concrete adapter by constant lookup and validates the config itself.
  #
  #   Rbrun.build(Rbrun::Sandbox, Rbrun.config.sandbox_provider, provider: :local)
  #
  def self.build(family_module, providers_config, provider: nil, **opts)
    raise ConfigError, ":default is reserved and cannot be selected as a provider" if provider == :default

    name = provider || providers_config.fetch(:default) do
      raise ConfigError, "no provider given and no :default configured"
    end

    provider_config = providers_config.fetch(name) do
      raise ConfigError, "no configuration for provider #{name.inspect}"
    end

    family_module.new(provider: name, config: provider_config, **opts)
  end
end
```

- [ ] **Step 4: Require the resolver from the entrypoint**

Modify `lib/rbrun.rb` — add the resolver require after config:

```ruby
require "rbrun/version"
require "rbrun/config"
require "rbrun/resolver"
require "rbrun/engine"

module Rbrun
  # Your code goes here...
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bin/rails test test/rbrun/resolver_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add lib/rbrun/resolver.rb lib/rbrun.rb test/rbrun/resolver_test.rb
git commit -m "feat(config): Rbrun.build config-aware constructor + ConfigError (constant lookup, fail-fast)"
```

---

### Task 3: Monorepo sub-gems wiring

**Files:**
- Create: `gems/.keep`
- Modify: `Gemfile`

**Interfaces:**
- Produces: the `gems/` directory and a Gemfile glob that auto-includes any `gems/<name>/<name>.gemspec` as a path gem. No gems exist yet, so the glob resolves to nothing (a safe no-op) until Phase 2 adds `rbrun-sandbox`.

- [ ] **Step 1: Create the sub-gems directory**

```bash
mkdir -p gems && touch gems/.keep
```

- [ ] **Step 2: Wire path-based sub-gems into the Gemfile**

Modify `Gemfile` — append, after the existing gems, this block:

```ruby
# Path-based sub-gems (rbrun-sandbox, rbrun-runtime, …) live under gems/.
# Each is auto-included as a path gem once its gemspec exists. No-op until then.
Dir.glob(File.expand_path("gems/*/*.gemspec", __dir__)).each do |gemspec_path|
  gem File.basename(gemspec_path, ".gemspec"), path: File.dirname(gemspec_path)
end
```

- [ ] **Step 3: Verify the bundle still resolves**

Run: `bundle check || bundle install`
Expected: `The Gemfile's dependencies are satisfied` (or a clean install). No new gems added.

- [ ] **Step 4: Commit**

```bash
git add gems/.keep Gemfile
git commit -m "chore: monorepo gems/ dir + path-gem glob for future sub-gems"
```

---

### Task 4: Dogfood spine + Phase 1 dogfood scenario

**Files:**
- Create: `lib/tasks/rbrun/dogfood/support.rb`
- Create: `lib/tasks/rbrun/dogfood/config.rake`

**Interfaces:**
- Consumes: `Rbrun.configure`, `Rbrun.config`, `Rbrun.reset_config!` (Task 1); `Rbrun.build`, `Rbrun::ConfigError` (Task 2).
- Produces:
  - `Rbrun::Dogfood.ok(label, cond) → Boolean` (prints `✓`/`✗ label`), `Rbrun::Dogfood.info(key, val)`, `Rbrun::Dogfood.header(text)` — shared by every future dogfood scenario.
  - rake task `dogfood:config` — the Phase 1 acceptance gate.

- [ ] **Step 1: Write the dogfood support spine**

Create `lib/tasks/rbrun/dogfood/support.rb`:

```ruby
# frozen_string_literal: true

# Shared helpers for rbrun dogfood scenarios. These are REAL runs, not tests: run a task and read
# the compact ✓/✗ output, then analyze. One scenario per .rake file in this directory.
module Rbrun
  module Dogfood
    module_function

    def ok(label, cond)
      puts "#{cond ? "✓" : "✗"} #{label}"
      cond
    end

    def info(key, val)
      puts "  #{key}: #{val}"
    end

    def header(text)
      puts "\n── #{text} #{"─" * [ 0, 50 - text.length ].max }"
    end
  end
end
```

- [ ] **Step 2: Write the Phase 1 dogfood scenario**

Create `lib/tasks/rbrun/dogfood/config.rake`:

```ruby
# frozen_string_literal: true

require "rbrun"
require_relative "support"

# Phase 1 dogfood — the config kernel, for real. Loads a config, resolves a provider by convention
# through the config-aware constructor (Rbrun.build), and proves a missing required key fails fast.
#
#   bin/rails dogfood:config

# A throwaway family that mimics a real provider gem: `.new(provider:)` resolves an adapter by
# constant lookup; the adapter validates the config it is handed.
module DogfoodDemoFamily
  def self.new(provider:, config:, **opts)
    const_get(provider.to_s.camelize).new(**config, **opts)
  end

  class Sqlite
    attr_reader :path

    def initialize(path: nil, **)
      raise Rbrun::ConfigError, "sqlite provider requires :path" if path.nil? || path.to_s.empty?
      @path = path
    end
  end
end

namespace :dogfood do
  desc "Phase 1: config kernel resolves a provider by convention and fails fast on a bad config"
  task :config do
    dog = Rbrun::Dogfood

    Rbrun.reset_config!
    Rbrun.configure do |c|
      c.database_connection = :rbrun
      c.tenancy_key         = "tenant"
      c.user email: "ben@dee.mx", password: "secret"
      c.sandbox_provider = { default: :sqlite, sqlite: { path: "/tmp/box.db" } }
    end

    dog.header "config parsed"
    dog.ok "flat knob defaulted (subprocess_timeout=900)", Rbrun.config.subprocess_timeout == 900
    dog.ok "tenancy_key = tenant", Rbrun.config.tenancy_key == "tenant"
    dog.ok "one user, default tenant rbrun",
           Rbrun.config.users == [ { email: "ben@dee.mx", password: "secret", tenant: "rbrun" } ]

    dog.header "provider resolved by convention"
    obj = Rbrun.build(DogfoodDemoFamily, Rbrun.config.sandbox_provider) # default: :sqlite
    dog.ok "resolved :sqlite → DogfoodDemoFamily::Sqlite", obj.is_a?(DogfoodDemoFamily::Sqlite)
    dog.ok "config injected (path=/tmp/box.db)", obj.path == "/tmp/box.db"

    dog.header "fail-fast on bad config"
    failed =
      begin
        Rbrun.build(DogfoodDemoFamily, { default: :sqlite, sqlite: {} })
        false
      rescue Rbrun::ConfigError => e
        dog.info "raised", e.message
        true
      end
    dog.ok "missing required key raised Rbrun::ConfigError", failed
  end
end
```

- [ ] **Step 3: Run the dogfood scenario**

Run (from the engine repo — the engine runner namespaces dummy-app tasks under `app:`):
`bin/rails app:dogfood:config`
(In a mounted host app it is the un-prefixed `bin/rails dogfood:config`.)
Expected output (all ✓):

```
── config parsed ─────────────────────────────────
✓ flat knob defaulted (subprocess_timeout=900)
✓ tenancy_key = tenant
✓ one user, default tenant rbrun

── provider resolved by convention ───────────────
✓ resolved :sqlite → DogfoodDemoFamily::Sqlite
✓ config injected (path=/tmp/box.db)

── fail-fast on bad config ───────────────────────
  raised: sqlite provider requires :path
✓ missing required key raised Rbrun::ConfigError
```

- [ ] **Step 4: Run the whole test suite (nothing regressed)**

Run: `bin/rails test`
Expected: PASS — the config + resolver tests plus the scaffold's `RbrunTest` version test, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/tasks/rbrun/dogfood/support.rb lib/tasks/rbrun/dogfood/config.rake
git commit -m "feat(dogfood): support spine + dogfood:config — Phase 1 acceptance gate"
```

---

## Self-Review

**1. Spec coverage (Phase 1 contract):**
- Monorepo layout (`gems/` path-deps, gemspec wiring) → Task 3. ✓
- `Rbrun.configure` DSL: flat knobs → Task 1; `<family>_provider` hash primitive → Task 1; reserved `default:` → enforced in `Rbrun.build`, Task 2; repeatable `c.user` → Task 1. ✓
- Config-aware constructor pattern (constant lookup + config injection) → `Rbrun.build`, Task 2. (Family-specific wrappers `Rbrun.sandbox`/`Rbrun.runtime` are deferred to their gems' phases by design — they are one-line calls to `Rbrun.build`.) ✓
- `lib/tasks/rbrun/dogfood/support.rb` spine → Task 4. ✓
- Deliverable tests: config parsing → Task 1; `.new(provider:)` constant lookup on a dummy family → Task 2 (`ResolverDummy`); adapter fail-fast on missing required key → Task 2 + dogfood; `default:` selection → Task 2. ✓
- Dogfood gate `dogfood/config.rake` → Task 4. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to". Every code and test block is complete. ✓

**3. Type/name consistency:** `Rbrun.config`/`configure`/`reset_config!`, `Config#<family>_provider`, `Config#user`, `Rbrun.build(family_module, providers_config, provider:)`, `Rbrun::ConfigError`, `Rbrun::Dogfood.{ok,info,header}` — used identically across Tasks 1→4 and both dummy families (`ResolverDummy`, `DogfoodDemoFamily`) implement the same `.new(provider:, config:, **opts)` contract `Rbrun.build` calls. ✓

**Note carried to Phase 2:** the family wrapper `Rbrun.sandbox(provider = nil, **opts) = Rbrun.build(Rbrun::Sandbox, Rbrun.config.sandbox_provider, provider:, **opts)` lands with `rbrun-sandbox`; `Rbrun.build` is already the tested mechanism it will call.
