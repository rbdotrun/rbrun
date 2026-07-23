# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> # 🛑 USE THE PRIMITIVES. ALWAYS. 🛑
>
> **This engine ships a full ported design system — `Rbrun::Ui::*` primitives + `Rbrun::` preset/folder
> components — reached through the `component(...)` / `preset(...)` / `custom(...)` helpers. Building UI
> means COMPOSING THESE. It does not mean writing HTML.**
>
> **NEVER hand-roll a raw HTML control when a primitive exists.** No bare `<input>`, `<button>`,
> `<select>`, `<textarea>`, `<dialog>`, `<table>`, menu, card, badge, avatar, tab, spinner, skeleton,
> list row, search box, dropzone — every one of these is already a primitive. `<input class="form-input-base">`
> is a BUG; it is `component("input", …)`. A raw `<button class="…">` is a BUG; it is `component("button", …)`.
>
> **Before writing ANY markup:** open `app/components/rbrun/ui/` and use what's there. If a primitive is
> *close but missing a prop*, extend the primitive (add the option, keep the API clean) — do not fork it
> into inline HTML. If a shape genuinely does not exist yet (e.g. a new skeleton/table variant), BUILD IT
> as a primitive (`Rbrun::Ui::<Name>::Component`, preset-based where variants apply), add it to the
> primitives smoke test, and compose that — so the next person inherits it too.
>
> **Why this is non-negotiable:** the primitives own the class strings that Tailwind actually scans and
> the design tokens/behaviours (a11y roles, keyboard nav, focus, motion) that raw HTML silently drops.
> Hand-rolled markup drifts, breaks theming, and skips the Stimulus wiring. One system, one surface —
> enforced here, not case by case.

> # 🛑 ALWAYS REACH A COMPONENT THROUGH THE `component(...)` HELPER. 🛑
>
> **NEVER instantiate a component class directly in a view.** `render(Rbrun::Ui::Badge::Component.new(label:, color:))`
> is a BUG; it is `component("badge", label:, color:)`. Same for every primitive: `component("table", …)`,
> `component("button", …)`, `component("surface", …)`, `component("drawer_panel", …)`, `component("badge", …)`.
> A bare `render(Rbrun::Ui::<Name>::Component.new(...))` — or `render(Rbrun::<Name>::Component.new(...))` — in
> ANY `.erb` is wrong, even when it "works".
>
> **Why:** `component(...)` (and its siblings `preset(...)` / `custom(...)`) is the ONE resolution seam — it
> maps a stable string name to the class, applies presets/variants, and keeps views decoupled from class
> paths and constructor signatures. Newing the class up in a view hard-codes the namespace, skips that
> seam, and drifts the moment a primitive is renamed, presetized, or moved. One helper, one door.
>
> **The only place a component class name appears literally is INSIDE another component** (a component
> composing a child via `render(Child::Component.new)` in its own `.rb`/template). In a **view** (`app/views/**`),
> it is ALWAYS `component("<name>", …)`.

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

10. **Exposure is a three-step ladder. Never collapse a step into the one before it. Each step is opt-in, reversible, and scoped to ONE service — enforced by the engine's OWN edge, never a provider's box-wide switch.**
    1. **Run** — starting a service runs a supervised process **inside the box** and exposes **nothing**. A declared `port` is only what the process binds to internally; it is *not* a request to expose it. `repo_services_start` must never resolve a URL or expose anything.
    2. **Preview** (optional) — a **separate, explicit, reversible** decision: `preview_service(name)` / `stop_preview(name)`, ungated. It gives the service a stable single-label host `<token>-preview.<preview_domain>` served by the engine's own proxy (`Rbrun::PreviewProxy`), which requires an **rbrun** session — so a teammate with an rbrun account, but no *provider* account, can view it. Intent lives on **`Rbrun::ServiceExposure`** (per `[worktree, name]`, so it survives the start-reset and addresses ONE sandbox — never a repo-level token). Launch only resolves the provider URL onto the run as the proxy's upstream for a service already declared previewed.
    3. **Public** (optional) — genuinely open: anyone with the link, no account. **`share_public(name)` MUST be `needs_approval!`** (a human decision, never the agent's); `stop_sharing(name)` is ungated. Public **requires** previewed, and `stop_preview` revokes it. Same host, now served anonymously by the proxy.
    - **Enforcement is real and per-service:** a service with no `ServiceExposure` token has no host and cannot surface, whatever it binds to. The sandbox is **kept private** — the proxy attaches the provider token server-side; it never reaches the browser.
    - **NEVER flip a provider's box-wide public switch** (e.g. Daytona `set_public`). It is per-sandbox, not per-port, so it would expose *every* service on the box — breaking the scoping this ladder exists to guarantee. The capability may exist on an adapter, but the engine must never call it (guarded by a test). A future provider with genuine per-port exposure is a different story.
    - **The engine IS a reverse proxy for previews** (`Rbrun::PreviewProxy`, Rack middleware at the top of the stack). Host-based (each preview at its own root) so the app's root-relative URLs just work. HTTP relayed via Faraday/async-http; WebSockets via `rack.hijack` byte-pump, capped by `preview_max_sockets` (each pins a Puma thread; on Falcon a fiber). The **control plane bypasses all of this** via `Rbrun.preview_edge` (`expose`/`revoke`) — set ⇒ the engine creates no DNS and serves no proxy; the host owns the data path.

11. **IDEMPOTENCY IS MANDATORY. A flow that leaves state behind is a leak, and a leak is a bug.** Every operation that touches external or shared state — sandboxes, DNS records, tunnels, webhooks, a dogfood's fixtures, `.env` — MUST converge on repeat: find-or-create (never blind-create), upsert (never blind-append), reap-at-start and/or destroy-at-end. Concretely: `bin/setup` finds-or-creates the tunnel and upserts one CNAME + one `.env` line; `rbrun-dns#upsert` is find-then-patch; `PreviewDomain.ensure!` upserts one wildcard; `Sandbox::Daytona#session_create` swallows the 409; `repo_services_start` is a kill-all-then-relaunch reset; a dogfood **reaps prior state at start and destroys its box in `ensure`** — never "leave it alive for validation" (a stopped box still holds disk; validate *during* the run). When you catch yourself about to create-without-checking or leave a resource behind, stop: that is the habit this rule exists to kill.

## Layout

- `lib/rbrun/` — engine kernel. Currently: `config.rb` (`Rbrun.configure`/`config`/`reset_config!`), `resolver.rb` (`Rbrun.build` + `Rbrun::ConfigError`).
- `gems/` — pure-Ruby provider sub-gems (path-deps, auto-globbed by the Gemfile once each gemspec exists). Empty until Phase 2.
- `app/`, `db/`, `config/` — the engine host (models, tools, UI) — populated in Phases 4–5.
- `lib/tasks/rbrun/dogfood/` — dogfood scenarios + `support.rb`.
- `test/dummy/` — the host app the engine boots against for tests and dogfood.
