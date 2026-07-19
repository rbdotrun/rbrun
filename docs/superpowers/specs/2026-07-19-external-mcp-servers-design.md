# rbrun — external MCP servers: manual exposure + per-turn staging + a host injection seam

**Date:** 2026-07-19
**Status:** Design for review. Authored by the control-plane effort as a handoff; revise + execute here.
Incorporates the engine review (R1–R4). **Companion:** the control-plane half (OAuth, per-tenant
injection, the user-library→workspace-copy model) is specced in `rbrun-controlplane`. This is the
**engine** half only.

---

## 1. Goal

Let the agent use **external MCP servers** during a run. rbrun already exposes its *own* tools as an
in-process MCP server inside `client.ts`; this adds **third-party MCP servers** (Stripe, Linear, Sentry,
a custom server, …), materialized into the sandbox per turn and connected by the SDK — declared
manually by a self-hoster, or injected per-tenant by a host at turn time.

Two consumption paths, one engine (the `config_resolver` pattern, verbatim):

- **Self-hosted:** the operator declares servers in `Rbrun.configure`, secrets inline. Static, DB-seeded.
- **SaaS (control plane):** a host **injection seam** supplies the servers per `(tenant, repo)` at turn
  time, secrets already resolved (OAuth minted fresh). The engine stages whatever it is handed.

**Explicitly out of scope: GitHub as an MCP connector.** rbrun already stages a repo-scoped GitHub
installation token (+ `gh`) into the sandbox (`config.github_pat`); a GitHub MCP server is redundant and
drags in an "app-managed / provider-minted-token" special case. Do **not** port it.

## 2. Non-negotiable shape (mirrors skills, PR #12)

1. **Tenant(workspace)-scoped only — no `user` axis in the engine.** The control plane resolves
   user-owned-vs-workspace-owned into one workspace-scoped set before it reaches rbrun.
2. **DB is the source of truth; config only seeds** (like `c.skill`/`c.user`). The runtime materializes
   from the DB (or the resolver), never from config at turn time.
3. **The injection seam wins when set.** `Rbrun.mcp_resolver` — when a host sets it, it is the source of
   the turn's servers (with secrets); unset ⇒ the static/DB path. Self-host unchanged.
4. **Secrets never outlive the turn.** The materialized `mcp.json` (tokens/keys filled) is written into
   the sandbox per turn and deleted in `ensure`, exactly like the Anthropic key config + `github_pat`.
5. **All three auth kinds:** `api_key` (stdio env), `bearer` (stdio env), `oauth` (http remote). No
   app-managed/provider-minted path (that was the GitHub case — cut).
6. **No silent truncation of tools.** If the per-turn tool budget (§7) drops any server/tool, `log()` it.

## 3. Config API (seed sources, self-hosted)

```ruby
Rbrun.configure do |c|
  c.mcp_server name: "stripe", transport: :stdio, auth: :api_key,
               command: "npx", args: ["-y", "@stripe/mcp@latest"],
               env: { "STRIPE_SECRET_KEY" => ENV["STRIPE_KEY"] },
               tools: %w[get_stripe_account_info create_payment_link], # exposed allowlist (§7); omit ⇒ ALL
               tool_permissions: { default: :needs_approval }          # always_allow | needs_approval | blocked

  c.mcp_server name: "linear", transport: :http, auth: :oauth, url: "https://mcp.linear.app"
end
```

Repeatable, like `c.user`/`c.skill`. Seeds `Rbrun::McpServer` rows (§5). Secrets in config are the
self-hosted convenience; the SaaS never uses this path.

## 4. The injection seam (the control-plane hook)

```ruby
# Set once at boot by the host. Given the acting tenant + the turn's repo, return the servers to
# materialize for THIS turn — secrets already resolved. nil ⇒ static/DB path.
Rbrun.mcp_resolver = ->(tenant, repo) { [ Rbrun::McpServer::Spec, ... ] }
```

**[R1] The repo comes from the record, not a controller.** `AgentTurn` runs in a **job** — there is no
controller session, so `current_repo` (a session-cookie value) is unavailable and would be nil. The
engine calls the resolver with the worktree's repo:

```ruby
Rbrun.mcp_servers_for(@session.tenant, @session.worktree.repo)
```

exactly as skills resolve tenant from `@session.tenant` (not the controller's `current_tenant`). The
seam signature is `(tenant, repo)`; the **source** of `repo` is `@session.worktree.repo`.

- Returns `Rbrun::McpServer::Spec` value objects (`name`, `transport`, `auth`, `command`/`url`,
  `args`, `env`/`headers`, `tools`, `tool_permissions`) — **already carrying live secrets**. The engine
  treats them as opaque and materializes them; it never mints or stores the host's tokens.
- Same idiom as `Rbrun.config_resolver` / `Rbrun.github_repos_resolver`: reentrant, set-once, pure read.

## 5. Data (rbrun DB, tenant-scoped)

- **`Rbrun::McpServer`** — `include Rbrun::Tenanted`. Columns: `name`, `transport` (`stdio|http`),
  `auth` (`api_key|bearer|oauth`), `command`, `args` (jsonb), `url`, `env` (jsonb, non-secret keys in the
  SaaS path; literal secrets allowed in the self-hosted path), `headers` (jsonb), `tools` (jsonb array —
  the exposed allowlist, §7; null ⇒ all), `tool_permissions` (jsonb), `enabled` (bool), `config_digest`
  (string, §9). Unique on `(tenant, name)`.
- `#to_spec` → the `Spec` value object the resolver/materializer consume.

## 6. Materialization + staging (the runtime)

In `AgentTurn#call_client` (where skills already stage):

1. Resolve: `specs = Rbrun.mcp_servers_for(@session.tenant, @session.worktree.repo)` (resolver if set,
   else `McpServer.for_tenant(tenant).where(enabled: true).map(&:to_spec)`).
2. Apply the **tool budget** (§7) → the effective, capped set of `(server, exposed_tools)`.
3. Materialize `mcp.json` into the sandbox workspace (`{ mcpServers: { name => stdio|http entry } }`),
   secrets filled; upload it.
4. Pass to the runtime → `client.ts` **merges** these into `query({ options: { mcpServers } })` alongside
   the in-process `rbrun` server (never replacing it). `allowedTools` extends to the exposed
   `mcp__<name>__<tool>` set, gated by `tool_permissions`.
5. `ensure`: delete the uploaded `mcp.json` (+ any token files). Secrets never persist in the box.

## 7. [R2] Tool budget — the SDK schema-deferral ceiling

`client.ts` already trims tools to stay under the SDK's threshold: **past some count the SDK ships tool
*names without schemas*, and the model calls tools blind** (the `enum_options: received undefined`
failure). External servers return their **full** `tools/list` regardless of granted scope (scope gates
execution, not discovery), so two chatty connectors (Stripe ≈ 10, Linear) blow straight past the line.
The design takes an explicit three-layer stance — never silent:

1. **`blocked` tools are never exposed** (first reduction, from `tool_permissions`).
2. **Per-server exposed allowlist (`tools`)** — a server exposes only its allowlisted tools; **omitting
   `tools` means all**, but the control plane sets it (default: a curated subset, not all). This is the
   primary lever.
3. **Hard per-turn cap.** Total exposed = built-ins + rbrun tools + MCP tools, capped under the SDK-safe
   threshold (the same constant `client.ts` already enforces). On overflow, drop lowest-priority MCP
   tools (priority: `always_allow` > `needs_approval`; then server declaration order) and **`log()`
   exactly what was dropped** (invariant §2.6). No silent truncation.

## 8. [R3] Approval for external MCP tools — park is reused, resume is a new branch

rbrun's gate parks a call, then on approval `run_frozen_call!` executes it **in Ruby** via
`ApplicationTool.find`. An `mcp__stripe__*` tool has **no Ruby entry** — `find` returns nil, so the
existing resume path cannot execute it. The two halves split:

- **Park — reused.** A `needs_approval` MCP tool routes through the SDK's `canUseTool` hook exactly like
  a rbrun tool: emit `needs_approval`, park the run, freeze the `tool_use` row. The frozen row records a
  **`tool_kind`** (`ruby | mcp`) and the tool name.
- **Resume — new branch (dispatch on `tool_kind`).**
  - `ruby` → the existing `run_frozen_call!` (Ruby executes, result fed back).
  - `mcp` → **the SDK/server executes it, not Ruby.** On approve, the decision is returned to the SDK's
    permission mechanism as **allow** for that parked call; the server runs the tool and its result
    flows back through the normal event stream. On reject, return **deny** (+ reason). Ruby never calls
    `ApplicationTool.find` for an `mcp__*` tool.

**The one implementation decision this task owns** (needs `client.ts` knowledge): how the SDK resumes a
parked `canUseTool` decision — either the permission callback resolves to allow/deny on continuation, or
the turn re-runs with the approved tool added to an allow-set the SDK honors. Pick the mechanism that
matches the current `canUseTool`/reconnect flow; do **not** treat it as "reuse the Ruby gate."

## 9. [R4] Seeder + divergence (self-hosted only; simpler than skills)

`Rbrun::McpSeeder` seeds `c.mcp_server` rows into the tenant table, **compare-never-clobber**. Unlike
skills (folders of files → content-addressed archives), an MCP server is a flat config record, so:

- **Detection:** a **`config_digest`** — a hash over the serialized config (transport/command/args/url/
  env-**keys**/auth/tools/tool_permissions), stored on the row. A source whose digest differs from the
  stored row is **diverged**.
- **Behavior: warn-only.** A divergence `log()`s a warning and **never overwrites** an edited DB row.
  There is **no reconcile UI, no Keep-stored/Reload** (that was skills' folder-diff need). In the SaaS
  path the seeder never runs (resolver-driven), so this is a self-hosted-only concern; a reconcile
  surface is a future follow-up if asked for.
- Boot seeding via `after_initialize` (guarded pre-migrate/no-DB) + `rbrun:mcp:seed`.

## 10. Dogfood gate

`dogfood/mcp.rake` — one real turn, real Claude + sandbox: seed ONE stdio MCP server (a trivial local
echo MCP, or Stripe stdio with a test key) into the DB → materialized from the DB → the agent calls an
`mcp__<name>__*` tool and the session log shows the tool_use/result. **Use an `always_allow` tool first**
(exercises §6/§7 without depending on the §8 resume branch). A second scenario covers the §8
`needs_approval` MCP park→approve→server-executes path once that branch lands. Real LLM + sandbox, no
stubs. ✓/✗.

## 11. Coordination note

The control plane sets `Rbrun.mcp_resolver`, owns all OAuth (discovery/DCR/PKCE/refresh) + the
user-library→workspace-copy model + the per-connector `tools` allowlist. The engine's only new host
surface is `Rbrun.mcp_resolver(tenant, repo)` + `c.mcp_server` + materialization + the §7 budget and §8
approval branch. Keep it symmetric with `config_resolver` and skills.
