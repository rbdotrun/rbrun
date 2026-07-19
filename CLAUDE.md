# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`rbrun` is a **mountable Rails engine** that is, conceptually, a standalone agentic-runner application — it owns its own database, assets, and (optional) auth, and mounts into a host app only for deployment convenience. It ports the "meat" of the insitix Claude SDK runner (agentic runner + skill pattern + sandbox backend) into provider sub-gems under a batteries-included engine.

**The design is the contract.** Before changing anything structural, read:
- `docs/superpowers/specs/2026-07-19-rbrun-port-design.md` — the full architecture + the fixed **5-phase contract**.
- `docs/superpowers/plans/*.md` — the just-in-time per-phase implementation plans.

Build order: **Phase 1 Skeleton+config kernel (done) · 2 Sandbox · 3 Runtime · 4 Engine host · 5 Engine UI.** Each phase is one spec→plan→execute cycle, validated by its dogfood before the next plan is written.

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

7. **Naming:** `Session`/`SessionMessage` = the conversation aggregate (renamed from insitix's `Chat`/`ChatMessage`). Keep it distinct from the sandbox **process session** (`session_exec`/`session_logs_follow`, the transport) and `sdk_session_id` (the SDK's resume handle).

8. **Own database + always-on tenancy.** Engine records connect via a `connects_to` toggle driven by `Rbrun.config.database_connection` (`:rbrun` isolated default | `:primary`). Every record carries a required tenant slug column (name = `c.tenancy_key`, default `"tenant"`; default slug value `"rbrun"`).

9. **RubyLLM is an engine-only dependency** — used solely for the tool base (`ApplicationTool < RubyLLM::Tool`) and its schema utilities. It must never leak into the pure sub-gems.

## Layout

- `lib/rbrun/` — engine kernel. Currently: `config.rb` (`Rbrun.configure`/`config`/`reset_config!`), `resolver.rb` (`Rbrun.build` + `Rbrun::ConfigError`).
- `gems/` — pure-Ruby provider sub-gems (path-deps, auto-globbed by the Gemfile once each gemspec exists). Empty until Phase 2.
- `app/`, `db/`, `config/` — the engine host (models, tools, UI) — populated in Phases 4–5.
- `lib/tasks/rbrun/dogfood/` — dogfood scenarios + `support.rb`.
- `test/dummy/` — the host app the engine boots against for tests and dogfood.
