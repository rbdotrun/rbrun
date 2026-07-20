# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`rbrun` is a **mountable Rails engine** that is, conceptually, a standalone agentic-runner application — it owns its own database, assets, and (optional) auth, and mounts into a host app only for deployment convenience. It packages an agentic Claude SDK runner — agentic runner + skill pattern + sandbox backend — as provider sub-gems under a batteries-included engine.

**The design is the contract.** Before changing anything structural, read:
- `docs/superpowers/specs/2026-07-19-rbrun-design.md` — the full architecture + the fixed **8-phase contract**.
- `docs/superpowers/plans/*.md` — the just-in-time per-phase implementation plans.

Build order: **1 Skeleton+config kernel · 2 Sandbox · 3 Runtime · 4 Persistence+config spine · 5 Tool base+turn loop · 6 Worktrees (GitHub) +auth (all done) · 7 Component DSL+primitives+assets · 8 Conversation UI.** Each phase is one spec→plan→execute cycle, validated by its dogfood before the next plan is written.

## Commands

Ruby 3.4.4, Rails `>= 8.1.3`. This is an engine, so `bin/rails` runs against `test/dummy` and namespaces engine rake tasks under `app:`.

- **Test suite:** `bin/rails test`
- **Single file:** `bin/rails test test/rbrun/config_test.rb`
- **Single test:** `bin/rails test test/rbrun/config_test.rb -n "/defaults/"`
- **CI equivalent:** `bin/rails db:test:prepare test`
- **Lint:** `bin/rubocop` (omakase; `-a` to autofix). CI runs `bin/rubocop -f github`.
- **Dogfood (engine repo):** `bin/rails app:dogfood:config` — the `app:` prefix is required here because the engine runner wraps the dummy app's tasks. (In a mounted host app it's the un-prefixed `bin/rails dogfood:config`.)

## Non-negotiable invariants

These are deliberate, hard-won decisions from the design phase. Do not "improve" them away.

1. **No registry. No self-registration. Ever.** Provider gems depend on **nothing** (the single exception is `rbrun-runtime → rbrun-sandbox`, a real functional dep). A family resolves its own adapter by **constant lookup in its own namespace** (`:daytona` → `Rbrun::Sandbox::Daytona`). Do not add a registry object, a `register.rb`, or any self-registration glob.

2. **The engine is the only composition root.** Pure sub-gems are config-agnostic: `Family.new(provider:, config:)` takes an **explicit** config hash and reads no global state. Only the engine reads `Rbrun.configure`, via `Rbrun.build(family_module, providers_config, provider:)` (see `lib/rbrun/resolver.rb`), which selects a provider and injects its config. Adapters **validate their own config, fail-fast**.

3. **Config convention:** every provider family is one hash — `c.<family>_provider = { default: :name, name: {…config…} }`. `:default` is reserved and can never be a provider name. Flat knobs (`database_connection`, `subprocess_timeout`, `github_pat`, `tenancy_key`) and repeatable `c.user email:, password:, tenant:` live alongside. See `lib/rbrun/config.rb`.

4. **The agentic loop is not in Ruby.** It runs as `client.ts` (Claude Agent SDK) **inside the sandbox** as a detached Bun process. Ruby is only transport (NDJSON stdout/stdin bridge), tool execution (tools run back in Ruby), and persistence. Terminal state comes **only** from the runner's own `result`/`error` events, never the transport.

5. **All outbound HTTP uses Faraday on the `async-http` adapter** (fork-safe under Falcon) — never Typhoeus/libcurl or vendor SDKs that bundle it. The one carve-out is a raw async-http streaming read for the sandbox `session_logs_follow` (the Faraday async adapter buffers the whole body).

6. **Dogfood is the per-phase acceptance gate, not the test suite.** Dogfood scenarios drive **one real turn** (real LLM, real sandbox, no stubs) and print `✓/✗` behavior signals — they catch what stubbed tests structurally can't (e.g. whether the SDK actually consults its approval gate). Rules: live in `lib/tasks/rbrun/dogfood/<scenario>.rake`, **one scenario per file**, shared `support.rb`; **never variabilized** (no ENV, no toggles — where two backends matter, write two files). A phase is "valid" when its dogfood is green.

7. **Naming:** `Session`/`SessionMessage` = the conversation aggregate. Keep it distinct from the sandbox **process session** (`session_exec`/`session_logs_follow`, the transport) and `sdk_session_id` (the SDK's resume handle).

8. **Own database + always-on tenancy.** Engine records connect via a `connects_to` toggle driven by `Rbrun.config.database_connection` (`:rbrun` isolated default | `:primary`). Every record carries a required tenant slug column (name = `c.tenancy_key`, default `"tenant"`; default slug value `"rbrun"`).

9. **RubyLLM is an engine-only dependency** — used solely for the tool base (`ApplicationTool < RubyLLM::Tool`) and its schema utilities. It must never leak into the pure sub-gems.

10. **Exposure is a three-step ladder. Never collapse a step into the one before it. Each step is opt-in, reversible, and scoped to ONE service.**
    1. **Run** — starting a service runs a supervised process **inside the box** and exposes **nothing**. A declared `port` is only what the process binds to internally; it is *not* a request to expose it. `repo_services_start` must never contact the proxy or resolve a URL.
    2. **Preview** (optional) — a **separate, explicit, reversible** decision: `preview_service(name)` / `stop_preview(name)`. It resolves a provider URL that **still requires the viewer's own provider authentication** (an anonymous stranger is bounced to the provider's login and never reaches the app). Ungated. The declaration lives on `RepoService#previewed` (the definition, so it survives the start-reset), and launch resolves a URL **only** for a service already declared previewed — honouring a prior decision, never implying one.
    3. **Public** (optional) — genuinely open: anyone with the link, no account. **`share_public(name)` MUST be `needs_approval!`** (a human decision, never the agent's); `stop_sharing(name)` is ungated because revoking is always safe. Public **requires** previewed, and `stop_preview` revokes it — a level can never be skipped. The flag lives on `RepoService#shared_public`, like `previewed`.
    - **Our model is per-service; enforcement is only as fine as the provider allows.** `shared_public` records intent per service and is the source of truth for the UI, the agent and revocation. Level 3 is implemented by the sandbox's optional `set_public(enabled)` capability. **Daytona's switch is per-SANDBOX, not per-port** — so every externally-bound port on that box becomes reachable, each at its own `<port>-<sandboxId>` host. That gap is an accepted, documented assumption (dev sandboxes are throwaway and their db/queue bind locally), **not** a guarantee we claim. A provider offering per-port control implements `set_public` honouring the port, and nothing above the adapter changes.
    - The provider switch goes back off only when **no** service is still shared — revoking one must never silently cut another.
    - **rbrun is not a reverse proxy.** Do not reintroduce an rbrun-owned public edge: putting ourselves in the request path breaks the app's root-relative URLs (assets/JS), and taxes every stream, upload and websocket forever.

## Layout

- `lib/rbrun/` — engine kernel. Currently: `config.rb` (`Rbrun.configure`/`config`/`reset_config!`), `resolver.rb` (`Rbrun.build` + `Rbrun::ConfigError`).
- `gems/` — pure-Ruby provider sub-gems (path-deps, auto-globbed by the Gemfile once each gemspec exists). Empty until Phase 2.
- `app/`, `db/`, `config/` — the engine host (models, tools, UI) — populated in Phases 4–5.
- `lib/tasks/rbrun/dogfood/` — dogfood scenarios + `support.rb`.
- `test/dummy/` — the host app the engine boots against for tests and dogfood.
