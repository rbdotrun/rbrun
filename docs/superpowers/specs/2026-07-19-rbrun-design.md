# rbrun — an agentic runner as a Rails engine + provider sub-gems

**Date:** 2026-07-19
**Status:** Design approved in principle; phases contracted. Per-phase plans written just-in-time.

---

## 1. Goal

`rbrun` is a Claude SDK runner built as a reusable, mountable Rails engine, decomposed into
provider-based sub-gems. Its core is "the meat": the **agentic runner**, the **skill pattern**, and
the **sandbox backend**.

`rbrun` is, ultimately, a **separate application** that happens to ship as a mountable engine purely
for frictionless deployment into a host Rails app. It owns its own database, its own assets, and
(optionally) its own auth. The engine mounts for deployment convenience; conceptually it is its own
product.

### What is out of scope

- **Domain-specific** tools and skills. rbrun ships only the **generic** runner machinery + a few
  generic built-in tools; any host-app domain entities and their tools/skills are the host's concern.
- A skills lockfile: the runner discovers skills by directory listing, never by lockfile.
- RubyLLM as a hard dependency of the sub-gems. It stays, but **scoped to the engine's tool base only**.

---

## 2. Architecture

### 2.1 Topology — monorepo: one engine + N plain-Ruby sub-gems (Rails' own pattern)

```
rbrun/                     ← the mountable engine (batteries-included host app) — the composition root
├─ rbrun.gemspec           ← path-depends on the sub-gems it uses
├─ gems/
│  ├─ rbrun-sandbox/       ← family :sandbox — normalized exec/file/session contract
│  │                          + adapters: local, daytona            (depends: NOTHING)
│  ├─ rbrun-runtime/       ← family :runtime — Runner transport + client.ts asset
│  │                          + Event port + adapter: claude_sdk     (depends: rbrun-sandbox)
│  ├─ rbrun-dns/       [FUTURE] family :dns     — cloudflare, route53, … (depends: NOTHING)
│  └─ rbrun-servers/  [FUTURE] family :servers — kamal+hetzner, …       (depends: NOTHING)
├─ app/                    ← engine host: models, tools, controllers, jobs, channels, views
├─ db/                     ← engine's OWN database (migrations, schema)
├─ lib/tasks/rbrun/dogfood/← dogfood scenarios (one .rake per scenario) + support.rb
└─ config/
```

**Dependency graph — the engine is the only thing that depends on the families:**

```
engine rbrun ──▶ rbrun-runtime ──▶ rbrun-sandbox      rbrun-dns[future]   rbrun-servers[future]
  owns Rbrun.configure + the         (runtime→sandbox            ▲                    ▲
  config-aware constructors           is the ONE real            └─ each provider gem depends on NOTHING
                                       functional dep)
```

- **Provider gems depend on nothing** and know nothing about config, about each other, or about any
  registry. The only inter-provider arrow is `rbrun-runtime → rbrun-sandbox`, a genuine functional
  need (the agent loop executes inside a sandbox). Each gem resolves its own adapters by constant
  lookup in its own namespace (`:daytona` → `Rbrun::Sandbox::Daytona`) and each adapter validates the
  config it is handed. **There is no registry and nothing registers itself.**
- **The engine is the composition root, "on top of all four."** It owns `Rbrun.configure` and the
  config-aware constructors that read config and hand explicit config to the pure gems. Adding
  `rbrun-dns` later = `require` it + set `c.dns_provider = {…}`; no provider ever changes and nothing
  is coupled to the future gems.

**Why sub-gems.** The runner (transport + loop) and the sandbox backend are plain Ruby with no
ActiveRecord. Extracting them keeps each independently testable and usable on its own, with an
explicit config hash, outside any Rails app.

### 2.2 The key insight

**The agentic loop is not in Ruby.** It is a self-contained `client.ts` (Claude Agent SDK
`query()`) that runs _inside the sandbox_ as a detached Bun process. Ruby is three things only:

1. **transport** — drives the loop over an NDJSON stdout/stdin bridge (a Daytona _process session_);
2. **tool execution** — app tools run back in Ruby via a stdio ping-pong;
3. **persistence / broadcast** — the host's concern.

Terminal state comes **only** from the runner's own `result`/`error` events, never from the
transport (hard-won reconnect discipline: on stream drop, re-check the process exitCode; if nil,
reconnect from the last byte offset).

Builtins (`Read`/`Write`/`Edit`/`Glob`/`Grep`/`Bash`) run **inside the sandbox** by the SDK (this is
how the agent edits files and runs `git`). App tools run **in Ruby**. The agent's work lives in the
Worktree's git branch and is persisted by the agent **committing + pushing to GitHub** via its own
git tools (see the Worktree model, Phase 6); rbrun records the commit SHAs.

> **Terminology — three distinct "session" concepts, kept separate throughout:**
>
> - **`Session` / `SessionMessage`** (§8) — the conversation aggregate and its per-event rows. The
>   user-facing thing.
> - **sandbox process session** (§2.3, `session_exec`/`session_logs_follow`) — the transport
>   primitive that drives one turn's detached `bun client.ts` over stdout/stdin.
> - **`sdk_session_id`** — the Claude Agent SDK's own resume handle, persisted on a `Session` and
>   passed as `resume:` to continue an SDK conversation.

### 2.3 Provider seam (the `.new(provider:)` requirement)

Both families are selected the same way: `.new(provider:)` on the family module, which resolves the
adapter by **constant lookup in its own namespace** and hands it explicit config. No registry, no
registration, nothing to boot.

```ruby
# family :sandbox — the pure gem, depends on nothing
module Rbrun::Sandbox
  def self.new(provider:, config: {}, **opts)
    const_get(provider.to_s.camelize).new(**config, **opts)   # :daytona → Rbrun::Sandbox::Daytona
  end                                                          # the adapter validates its own config, fail-fast
end

sandbox = Rbrun::Sandbox.new(provider: :daytona, config: { api_key:, api_url: }, labels: { session: 42 })
sandbox.exec(cmd, timeout:) / .exec_stream(...) { |chunk| } / .upload(files)
sandbox.read(path) / .exist?(path) / .glob(dir) / .create_folder(path) / .destroy!
sandbox.session_create(sid) / .session_exec(sid, cmd) → cmd_id
sandbox.session_input(sid, cmd_id, data) / .session_command(sid, cmd_id)
sandbox.session_logs_follow(sid, cmd_id, skip:) { |chunk| } → offset
# value objects (defined in rbrun-sandbox): ExecResult(exit_code, stdout, stderr), FileUpload(source, destination)

# family :runtime  (provider = the sandboxed RUNNER; vendor is the runner's concern) — depends on rbrun-sandbox
runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox:, config: { anthropic_api_key:, model:, max_turns: })
runtime.run(
  prompt:, system:, tools:, skills:, resume:,
  tool_handler: ->(req) { { result:, is_error: } },   # runs the tool in Ruby
  on_event:     ->(evt) { ... }                        # normalized Event stream
)
```

**Adapter resolution & credentials.** `provider.to_s.camelize` → the adapter constant inside the
family's namespace. Adding an adapter = drop a class in that namespace; nothing else. Each adapter
validates the config it is handed at init (fail-fast) — validation lives on the adapter that owns
those credentials, not in any shared schema.

**Engine convenience (the config-aware constructor).** The pure gem always takes explicit `config:`.
The engine is the only thing that knows the defaults, so it wraps the gem, reading `Rbrun.configure`:

```ruby
module Rbrun            # in the engine — reads config, injects it into the pure gem
  def self.sandbox(provider = config.sandbox_provider[:default], **opts)
    Rbrun::Sandbox.new(provider:, config: config.sandbox_provider.fetch(provider), **opts)
  end
end
```

**Normalized `Event`** (defined in `rbrun-runtime`): one struct for every runner, vendor specifics
land in `raw`. Event types cover the NDJSON protocol: `session · token · assistant · tool_request ·
builtin_tool_use · builtin_tool_result · needs_approval · result · error`. Each runner adapter
implements `#to_canonical(raw_line)` so `codex`/`gemini` runners can slot in later without changing
the host.

### 2.3b HTTP invariant (all outbound HTTP)

**Every outbound HTTP call in every gem uses Faraday on an async-ready adapter** (`async-http`), never
Typhoeus/libcurl (libcurl is not fork-safe under Falcon; the official vendor SDKs that bundle it are
deliberately avoided). This is a hard, cross-cutting rule: `rbrun-sandbox` (daytona), `rbrun-runtime`
(any HTTP a runner adapter makes), and the future `rbrun-dns`/`rbrun-servers` all build their clients
on Faraday + async-http. There is one documented exception — a **raw async-http** streaming read for
`session_logs_follow` (the Faraday async adapter buffers the whole body, which deadlocks a follow that
only closes on process exit) — in the daytona adapter.

### 2.4 Skill pattern (lives in `rbrun-runtime`)

A skill = a **folder** with a `SKILL.md` (YAML frontmatter `name`/`description` + markdown body,
optional `references/`, `examples/`). Discovery is filesystem-only; **no Ruby or TS ever names a
skill**: Ruby stages `skills/**/*` → `<workspace>/.claude/skills/`; `client.ts` `readdirSync`s that
dir → `skills:` option (auto-adds the `Skill` tool). "Dropping a folder in is the whole of adding a
capability." The engine ships zero domain skills; host apps and the agent add their own.

### 2.5 Tools (engine-owned, host-extensible)

The sub-gems are tool-agnostic. The engine owns tools:

- `Rbrun::ApplicationTool < RubyLLM::Tool` — base class; RubyLLM is used **only** here, for the tool
  DSL + `ruby-llm-schema` param utilities. `self.manifest` / `self.find(name)` / `needs_approval!` /
  `#execute(**) → { "data" } | { "error" }` (string-keyed).
- Generic built-in tools shipped by the engine (e.g. an identity tool). The agent's *work* is git
  commits it makes via its own Bash/git tools inside the Worktree's sandbox — not a tool that lifts
  bytes into the DB.
- Host apps add their own tools to the engine's tool list (`Rbrun.tools`). Tools resolve to the
  agent's manifest and dispatch via the `tool_handler` bridge.

---

## 3. Configuration interface — `Rbrun.configure`

Owned by the **engine** (the composition root). A `<family>_provider` key is simply read by that
family's config-aware constructor; no gem contributes or registers anything. Filled by the host in
one initializer.

```ruby
Rbrun.configure do |c|
  # ── flat knobs (single level) ──────────────────────────────────
  c.database_connection = :rbrun            # :rbrun (own DB) | :primary (host DB). See §4.
  c.subprocess_timeout  = 900
  c.github_pat          = ENV["GITHUB_PAT"] # agent's GitHub access; staged into sandbox per-turn (§5)
  c.tenancy_key         = "tenant"          # name of the required slug column scoping every record (§6)

  # ── optional built-in auth (repeatable; omit ⇒ host supplies current_tenant) (§6) ──
  c.user email: "ben@dee.mx",     password: ENV["RBRUN_PW"], tenant: "notiplus"
  c.user email: "alice@acme.com", password: ENV["ALICE_PW"], tenant: "acme"

  # ── providers: always a hash, always `<family>_provider` ──────
  # `default:` = the selected provider; every other key is a provider name → its config (credentials
  # + per-provider knobs). The whole hash is handed to the adapter, which validates it (fail-fast).
  c.runtime_provider = {
    default:    :claude_sdk,
    claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_API_KEY"], model: "sonnet", max_turns: 60 },
  }
  c.sandbox_provider = {
    default: :daytona,
    # daytona builds a self-built, content-addressed snapshot from `dockerfile` (the HOST injects its
    # own image; a minimal bun+shell default applies when omitted). `cpu`/`memory`/`disk` bake on it.
    daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"],
               dockerfile: ENV["RBRUN_SANDBOX_DOCKERFILE"], cpu: 2, memory: 4, disk: 3 },
    local:   {},
  }
  # future families — light up when their gem is required:
  c.dns_provider    = { default: :cloudflare,    cloudflare:    { api_token: ENV["CF_API_TOKEN"] } }
  c.server_provider = { default: :kamal_hetzner, kamal_hetzner: { hcloud_token: ENV["HCLOUD_TOKEN"] } }
end
```

**Rules:**

- Pure gems are config-agnostic: `Rbrun::Sandbox.new(provider:, config:)` takes an **explicit** config
  hash and reads no global state. The engine owns the config-aware constructors that read
  `Rbrun.configure` and inject the right hash: `Rbrun.sandbox` (no `provider:`) uses `default:`;
  `Rbrun.sandbox(:local)` picks a provider; either way the agent can override per call.
- `:default` is reserved inside every `*_provider` hash and cannot be a provider name.
- Validation is the adapter's job: it validates the config hash it is handed at init; a missing/blank
  required key fails fast. (At boot the engine can eagerly construct the `default:` adapter to
  surface config errors immediately.)
- Config-key → gem: `runtime_provider`→`rbrun-runtime`, `sandbox_provider`→`rbrun-sandbox`,
  `dns_provider`→`rbrun-dns`, `server_provider`→`rbrun-servers`.

### Two-tier configuration (forward-looking)

1. **Boot credentials** → `Rbrun.configure` (secrets, environment-level).
2. **Saved named configurations** the _agent_ creates and reuses (a Kamal deploy target "prod-eu", a
   DNS zone) → DB-persisted engine records + agent tools. `rbrun-dns`/`rbrun-servers`-era; out of
   scope for the phases below, but the config seam is designed to accommodate it.

---

## 4. Database strategy

`Rbrun::ApplicationRecord` is abstract; connection is toggled by `c.database_connection`:

```ruby
module Rbrun
  mattr_accessor :database_connection   # set from Rbrun.configure, default :rbrun
end

class Rbrun::ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  if Rbrun.database_connection && Rbrun.database_connection != :primary
    connects_to database: { writing: Rbrun.database_connection }
  end
end
```

- **`:rbrun` (default, isolated):** engine tables live in a separate physical DB. Host adds a `rbrun`
  key under each environment in its `database.yml` (the only structural burden on the host). Isolated
  `migrations_paths`; migrated via `rails db:migrate:rbrun`.
- **`:primary` (escape hatch):** everything in the host's primary DB; migrations merge into the
  host's normal `db/migrate` via `rbrun:install:migrations` and run under `db:migrate`.
- The `rbrun:install` generator wires the correct mode (it is one decision surfaced in two places —
  connection toggle + migration path must move together).
- `Rbrun.database_connection` must be set **before** `ApplicationRecord` loads → set it early via the
  engine's config defaults; host overrides go in an initializer that runs before the models load.

---

## 5. Assets (bun)

The engine ships **pre-built** bundles; the host's pipeline (Propshaft — Rails 8 default) serves
them. `bun build` (JS) + bun-run Tailwind (CSS) output to `app/assets/builds/rbrun/`; the engine
registers the path + precompile in an initializer. Bun is a dev/release dependency only — the host
never runs it; compiled bundles are shipped in the gem. Namespaced (`rbrun.js`/`rbrun.css`) to avoid
host collisions.

**GitHub PAT staging:** the runtime injects `c.github_pat` into the sandbox per-turn (git credential
helper / `GH_TOKEN`) so the agent can run git/`gh` inside the sandbox, cleaned up in `ensure` so it
never outlives the turn (same hygiene as the Anthropic key config file).

---

## 6. Tenancy & auth (engine)

- **Tenancy is always on.** Every engine record includes `Rbrun::Tenanted`, which adds a
  `<tenancy_key>` **slug column** (`NOT NULL`, indexed), a `for_tenant(slug)` scope, and default
  scoping. The column/concept name defaults to `"tenant"` (set once via `c.tenancy_key`); the default
  slug **value** — used when a `c.user` omits `tenant:`, and in the auth-off / single-tenant case — is
  `"rbrun"`.
- **Config users are real, extensible DB rows.** Users declared with `c.user` are **upserted into
  rbrun's own `users` table on boot** (find-or-create by email; password + tenant reconciled from
  config). The DB row — not the config line — is the canonical `Rbrun::User` entity, so it can be
  **extended with more columns later** (roles, settings, per-user keys, …) without changing the
  config contract. Config stays the declarative source for the auth-critical fields; anything added
  later lives on the row.
- **Auth is optional and overridable.** Any `c.user` present ⇒ built-in session auth (email/password)
  - a login screen. **No** `c.user` ⇒ auth off; the engine resolves the slug via the host-supplied
    `Rbrun.current_tenant` hook (falling back to the default slug `"rbrun"`).
- Users carry their tenant slug (`c.user email:, password:, tenant:`), so login resolves
  `current_tenant`.

---

## 7. Dogfood runtime (the per-phase acceptance gate)

Dogfood is **the** validation mechanism — not the test suite. The suite necessarily stubs the Runner,
so it proves the Ruby half and nothing the agent actually does (whether the SDK consults
`canUseTool`, whether the agent reads a skill before acting, whether generated SQL runs first try).
Dogfood drives **one real turn** — real LLM, real sandbox, no stubs — and prints compact ✓/✗ behavior
signals.

**Conventions (fixed):**

- Location: `lib/tasks/rbrun/dogfood/<scenario>.rake` — **one scenario per file** — plus a shared
  `lib/tasks/rbrun/dogfood/support.rb` (`Rbrun::Dogfood` helper module: `quiet!`, tenant/conversation
  helpers, `turn`, `called`, `payloads`, `reply`, `errors`, `ok`, `info`).
- **Dogfood is never variabilized.** No ENV toggles, no `PROVIDER=…`. Each scenario is fixed and
  deterministic — hardcoded prompt, hardcoded provider, hardcoded assertions. Where two backends both
  matter, they are **two separate scenario files**, each hardcoded.
- Real runs go through the same path the app takes (`Session#run_turn` once the engine exists), never
  a lower-level shortcut that skips status/broadcast — a dogfood must see what the user sees.
- Output is ✓/✗ + the tools each turn called + the reply; a human reads and analyzes.

Dogfood is enabled incrementally: each phase adds the scenario(s) that prove _that phase's_ real
behavior, and a phase is "valid" when its dogfood passes.

---

## 8. Phase contract

Eight phases. Scope + dogfood gate are **fixed now**. Each phase's detailed plan is written
just-in-time (via the writing-plans skill), executed, validated by its dogfood, then the next phase's
plan is written. Numbering is 1–8. (The engine host was split from one oversized phase into three —
Phases 4, 5, 6; the UI was split into the component-DSL/design-system foundation, Phase 7, and the
conversation UI on top of it, Phase 8.)

### Phase 1 — Skeleton + config kernel + dogfood spine

**Scope:** monorepo layout (`gems/` path-deps, engine `gemspec` wiring); the engine's `Rbrun.configure`
DSL (flat knobs + the `<family>_provider` hash primitive + reserved `default:` + repeatable `c.user`);
the config-aware constructor pattern (`Rbrun.sandbox`/`Rbrun.runtime` — reading config, injecting an
explicit hash into a pure family's `.new(provider:)` which resolves by constant lookup); the
`lib/tasks/rbrun/dogfood/support.rb` spine. No provider gems and nothing backend-runnable yet.
**Deliverables:** engine config kernel with unit tests (config parsing; `.new(provider:)` constant
lookup on a dummy in-test family; adapter fail-fast on a missing required key; `default:` selection).
**Dogfood gate — `dogfood/config.rake`:** load a config, resolve a dummy provider by convention
through the config-aware constructor, confirm a missing required key fails fast. ✓/✗.

### Phase 2 — `rbrun-sandbox` (sandbox backend)

**Scope:** normalized sandbox contract (`exec/exec_stream/upload/read/exist?/glob/create_folder/
session_create/session_exec/session_input/session_command/session_logs_follow/destroy!`) +
`ExecResult` + `FileUpload`; `sandbox_provider` family registration; **`local`** adapter (real host/
docker executor) + **`daytona`** adapter (`Daytona::Client`/`Workspace`: Faraday-on-async-http,
label-addressed, raw async-http for `session_logs_follow`). Depends on Phase 1.
**Deliverables:** `rbrun-sandbox` gem; unit tests for pure logic; local-adapter integration test.
**Dogfood gates (two files, each hardcoded):**

- `dogfood/sandbox_local.rake` — `:local`: create → upload a file → `exec echo` → glob →
  `session_exec` a streaming command → read output → `destroy!`. ✓/✗.
- `dogfood/sandbox_daytona.rake` — same script on `:daytona` (real box). ✓/✗.

### Phase 3 — `rbrun-runtime` (AI runtime — **dogfood runtime becomes real**)

**Scope:** Runner transport decoupled from any model (injected `sandbox` + config + `on_event` +
`tool_handler`); `client.ts` shipped as a gem asset; staging (`bun install`, skill-staging,
`.claude/settings.json`, per-turn `config.json` with the API key deleted in `ensure`); **GitHub PAT
staging** into the sandbox per-turn; tool-manifest protocol; normalized `Event` port + `to_canonical`;
`runtime_provider` family registration; **`claude_sdk`** adapter. Depends on Phase 2.
**Deliverables:** `rbrun-runtime` gem; unit tests for the pure stream-parsing/dispatch/reconnect
functions (factored out to be testable without a sandbox).
**Dogfood gate — `dogfood/runtime.rake`:** a **real agent turn** via
`Rbrun::Runtime.new(provider: :claude_sdk, sandbox: Rbrun::Sandbox.new(provider: :local)).run(...)`
with a hardcoded prompt, ONE trivial in-memory tool, and a skill folder. ✓/✗: `session` emitted,
assistant replied, the tool was requested and answered over the bridge, terminal `result`. Real LLM +
real sandbox, **no engine**. This is the headline "dogfood runtime."

### Phase 4 — Engine host: persistence + config spine

**Scope:** the full `Rbrun.configure` aggregator (all `<family>_provider` hashes + flat knobs +
repeatable `c.user`) and the config-aware constructors `Rbrun.sandbox` / `Rbrun.runtime` (thin
wrappers over `Rbrun.build`, reading config, injecting an explicit hash into the pure gem);
`database_connection` toggle on `Rbrun::ApplicationRecord` (`connects_to`); models `Session` (status
enum, `sdk_session_id`, `#sandbox` via `Rbrun.sandbox`) + `SessionMessage` (one row per event,
`payload` jsonb, approval columns, `tool_use_id`); `Rbrun::Tenanted` (configurable `<tenancy_key>`
slug column — `NOT NULL`, indexed — + `for_tenant(slug)` scope, default slug `"rbrun"`);
`rbrun:install` generator + own-DB migrations; engine mounted in `test/dummy`. Depends on Phase 3.
**Deliverables:** model + config unit tests; migrations; the generator. No turn loop yet.
**Dogfood gate — `dogfood/session_log.rake`:** create a `Session` as a tenant, append `SessionMessage`
event rows, and confirm they persist, scope by tenant (`for_tenant`), and that `sdk_session_id` stores
— plus `Rbrun.sandbox`/`Rbrun.runtime` resolve from config. (No real turn yet.)

### Phase 5 — Engine host: tool base + turn loop

**Scope:** `Rbrun::ApplicationTool < RubyLLM::Tool` base + `manifest`/`find` tool lookup + `in_chat`
tenancy + generic built-ins (an identity tool + one simple demo tool); `Rbrun::AgentTurn` — the
`ingest` event-sink (→ `SessionMessage` rows) + the `run_tool` stdio bridge; `Session#run_turn` wiring
`Rbrun::Runtime.run` (`tools: ApplicationTool.manifest`, `tool_handler: run_tool`, `on_event: ingest`)
→ persistence, with status transitions (`working`/`done`/`needs_approval`/`failed`) and gate freezing.
Host apps register their own tools. Depends on Phase 4.
**Deliverables:** tool + turn tests (Runtime stubbed for the Ruby half); config-seeded dev tenant.
**Dogfood gates (through `Session#run_turn` — real turns):**

- `dogfood/session_turn.rake` — a real turn; ✓/✗ on tools called + reply + no tool errored.
- `dogfood/gate.rake` — a `needs_approval!` tool actually **parks** the run (`status=needs_approval`,
  a pending `tool_use` row frozen, nothing ran), and Bash confinement holds.

### Phase 6 — Engine host: Worktrees (GitHub-backed) + auth

The deliverable is **git history on GitHub**, not byte-blobs in the DB. A **`Worktree`** (rbrun's
term — *not* a git worktree) is the unit of work:

- **1 Worktree = 1 sandbox + 1 git branch**, spun on creation (a branch off a base ref in a repo).
- **`Worktree has_many :sessions`.** Every Session (conversation) under a Worktree runs its turns in
  that **same** sandbox, on that **same** branch — multiple conversations accumulate one working copy.
- The **sandbox belongs to the Worktree**, not the Session: this **relocates** `Session#sandbox`
  (shipped in Phase 4) to `Worktree#sandbox` (`Rbrun.sandbox(labels: { worktree: id })`); `Session
  belongs_to :worktree` and reads its sandbox/branch through it.
- **Tenancy roots on the Worktree** (the `<tenancy_key>` slug); Sessions derive their tenant from it.
- The **agent commits + pushes via git tools** (Bash) during turns — nothing auto-commits. rbrun
  **records the resulting commit SHAs** (a lightweight `Commit`/turn reference; GitHub is the store).

**Scope:** `Worktree` model (repo + base + branch + `#sandbox`, `Tenanted`, `has_many :sessions`) +
its provisioning (create branch off base, clone/checkout in the sandbox, using the config `github_pat`);
relocate the sandbox from `Session` to `Worktree` (+ `Session belongs_to :worktree`); record per-turn
commit SHAs (read from git after the turn); optional built-in auth — `User` model + config-seeded users
(idempotent upsert on boot; extensible DB row) + the `current_tenant` hook (host override when auth is
off). A Worktree is created against `{ repo:, base: }` (caller-provided or a config default). Depends
on Phase 5.
**Deliverables:** Worktree + Session-relocation + auth tests.
**Dogfood gate — `dogfood/worktree.rake`:** create a Worktree (spins a branch + sandbox), run a real
turn in a Session under it where the agent edits a file and `git commit`+`push`es via its tools, and
confirm the commit landed on the branch (GitHub) and its SHA was recorded.

### Phase 7 — Component DSL + primitives + assets pipeline

The design-system foundation the conversation UI (Phase 8) is built from — a ViewComponent DSL; the
`view_component` gem is imported and the DSL is defined here.

**Scope:** `Rbrun::ApplicationViewComponent` base — `view_component-contrib` + `Dry::Initializer`
(`option`/`param`) + `StyleVariants` (`style do … variants`) + `tailwind_merge` postprocess + inline
`erb_template`; the `component("name", …)` string-render helper + Stimulus auto-wiring
(`controller_name`/`merged_data`); the ~6 primitives the conversation UI needs (spinner, button,
badge, card, code_block, tooltip); Tailwind **v4** config (with the `default-*` brand palette) + the
**bun** build wiring output to `app/assets/builds/rbrun/`; `lucide-rails` icons. Identity is optional
(no `Dry::Effects.Reader(:current_user)`) and the `ApplicationHelper` keeps only `component`/`svg` (no
domain helpers). Depends on Phase 6.
**Deliverables:** the DSL base + primitives with component render tests; the Tailwind+bun build
producing `app/assets/builds/rbrun/{rbrun.css,rbrun.js}`.
**Dogfood gate — `dogfood/components.rake`:** render each primitive through the DSL (variants + a
`css:` override that tailwind-merges) and assert the HTML — proving the `option`/`style`/`erb_template`
DSL and the `component()` helper work end to end.

### Phase 8 — Engine UI (conversation, controllers, jobs, channels, Turbo, auth screen)

**Scope:** `MessagesController` / `ApprovalsController` (atomic `decide_approval!`, resume via job),
the three thin turn jobs, the broadcast engine (`Session#broadcast_event` → append-new-segment vs
replace-in-place, `segment_locals_for`, `broadcast_status`/`_composer`/`_working`, the `SessionMessage`
after-commit callbacks with tokens coalesced server-side), Turbo Stream views + the
`timeline`/`segment`/`turn`/`base` components (built on Phase 7's primitives), the 3 Stimulus
controllers (autoscroll, composer, sticky_details), routes, login screen (when auth is on), a Worktree
commit/diff pane, engine mounted + navigable in `test/dummy`. Depends on Phase 7.
**Deliverables:** working mounted UI; controller/system tests.
**Dogfood gate — `dogfood/browser.rake`:** drive a real conversation in a headless browser: Turbo
appends the turn, the working indicator shows, the approval footer appears and a decision resumes the
turn, the branch's new commits render. ✓/✗ + screenshots.

---

## 9. Future (in-spec, not phased)

- **`rbrun-dns`** — family `:dns`; adapters for major DNS providers (cloudflare, route53, …) to set up
  domain configs remotely. Exposed to the agent as tools; DB-persisted named zone configs for reuse.
- **`rbrun-servers`** — family `:servers`; an HTTP interface to deploy apps into environments via
  Kamal. Exposed to the agent as tools; DB-persisted named deploy targets for reuse.
- Both are pure gems that depend on nothing; they plug in via the `Rbrun.configure` `<family>_provider`
  convention + a config-aware constructor in the engine — no changes to any other gem.
- Additional runner providers (`codex`, `gemini`) via new `runtime_provider` adapters implementing
  `#to_canonical` — no host changes.

---

## 10. Component layering (coupling map)

- **Plain Ruby / no framework coupling:** `Daytona::FileUpload`, the `client.ts` agent (domain-free),
  the normalized `Event`/`Usage` structs, the convention-based `.new(provider:)` constant lookup.
- **Plain Ruby with light deps (credentials/logger/root injected):** `Daytona::Client`/`Workspace`,
  `ClaudeSdk::Runner` (its only AR touchpoint is the sandbox + credentials → injected).
- **Engine host (Rails/AR/Turbo-coupled):** `AgentTurn` (the `on_event`/`tool_handler` sink),
  `ApplicationTool`/`AgentTools`, `Worktree`/`Session`/`SessionMessage` (the conversation aggregate;
  work is GitHub git history), controllers/jobs/channels.

```

```
