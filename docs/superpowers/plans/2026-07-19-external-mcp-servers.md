# External MCP servers — Implementation Plan (rbrun engine)

> **Read this first.** The goal is fixed and specced: `specs/2026-07-19-external-mcp-servers-design.md`.
> This is the **critical-path dependency** — the control-plane half (user library → workspace copy →
> per-repo activation → OAuth) is **already built and unit-tested behind the seam**; it is waiting on
> exactly one thing from you: a stable `Rbrun.mcp_resolver(tenant, repo)` returning `McpServer::Spec[]`.
> Your review (R1–R4) is **already folded into the spec below** — they are tasks now, not open
> questions. **Execute; do not re-open the goal.** The moment the seam + Task 6 land, we integrate.

**Goal:** External MCP servers materialized into the sandbox per turn (from DB, or a host resolver),
connected by the SDK alongside rbrun's in-process tool server, gated by a tool budget + per-tool
permissions.

## Global constraints
- Tenant(workspace)-scoped only — **no `user` axis**.
- DB is source of truth; `c.mcp_server` only seeds.
- `Rbrun.mcp_resolver(tenant, repo)` wins when set; unset ⇒ static/DB path.
- Materialized `mcp.json` deleted in `ensure` — secrets never outlive the turn.
- **No GitHub connector.** No silent tool truncation (`log()` drops).

---

### Task 1: `McpServer::Spec` value object + `c.mcp_server`
- `Spec = Data.define(:name, :transport, :auth, :command, :args, :url, :env, :headers, :tools, :tool_permissions)`.
- `Config#mcp_server(name:, transport:, auth: nil, command: nil, args: [], url: nil, env: {}, headers: {}, tools: nil, tool_permissions: {})` — repeatable, like `#user`/`#skill`.
- Tests: parses stdio + http; unknown `transport`/`auth` fail fast.

### Task 2: `Rbrun::McpServer` model + migration (tenant-scoped)
- Migration `rbrun_mcp_servers`: `tenant` NOT NULL, `name`, `transport`, `auth`, `command`, `args` jsonb,
  `url`, `env` jsonb, `headers` jsonb, `tools` jsonb, `tool_permissions` jsonb, `enabled` bool default
  true, `config_digest` string, timestamps; unique `(tenant, name)`.
- Model: `include Rbrun::Tenanted`; string enums; `#to_spec`; `#compute_digest`.
- Tests: tenancy scope, uniqueness, `to_spec` round-trip, digest stable across reorderings.

### Task 3: `Rbrun::McpSeeder` + boot seeding  **[R4 — warn-only, digest-based, no reconcile UI]**
- Seed `c.mcp_server` → DB, compare via `config_digest`: `created | unchanged | diverged`. A divergence
  **`log()`s a warning and never overwrites** an edited row. **No Keep-stored/Reload, no panel.**
- `after_initialize` boot seed (guarded pre-migrate/no-DB) + `rbrun:mcp:seed`.
- Tests: seed creates; re-seed idempotent; an edited row (digest differs) is left intact + warns.

### Task 4: `Rbrun.mcp_resolver` seam  **[R1 — repo from the record]**
- `attr_writer :mcp_resolver`; `Rbrun.mcp_servers_for(tenant, repo) = @mcp_resolver ? @mcp_resolver.call(tenant, repo) : McpServer.for_tenant(tenant).where(enabled: true).map(&:to_spec)`. `reset_config!` clears it.
- Tests: unset ⇒ DB path; set ⇒ resolver drives; **called with `(tenant, repo)`** — assert the engine
  passes `@session.tenant` + `@session.worktree.repo`, NOT any controller value.

### Task 5: `Rbrun::Mcp::Materializer` + `Rbrun::Mcp::ToolBudget`  **[R2]**
- `Materializer.call(specs) -> { "mcpServers" => { name => stdio|http entry } }` (pure; secrets from the
  Spec land in output).
- `ToolBudget.apply(specs, builtin_count:, rbrun_count:) -> capped specs` — drop `blocked`, honor each
  server's `tools` allowlist (nil ⇒ all), enforce the hard cap under the SDK threshold (priority
  `always_allow` > `needs_approval` > declaration order), and **`log()` every dropped tool/server**.
- Tests: stdio + http shapes; allowlist filters; over-cap drops lowest-priority + logs; nothing silent.

### Task 6: Stage into the turn (`AgentTurn#call_client`)  **[R1]**
- `specs = Rbrun.mcp_servers_for(@session.tenant, @session.worktree.repo)` → `ToolBudget.apply` →
  `Materializer` → upload `mcp.json`; pass to `runtime.run(..., mcp: ...)`. `ensure`: delete `mcp.json`.
- Tests (Runner stubbed): uploads a materialized `mcp.json` keyed off `worktree.repo`; deletes in `ensure`.

### Task 7: `client.ts` — merge external servers + allowed-tools
- Read the staged `mcp.json`; merge its `mcpServers` into `query({ options: { mcpServers } })` **alongside**
  the in-process `rbrun` server. Extend `allowedTools` with the exposed `mcp__<name>__<tool>` set. Respect
  the same tool-count ceiling the file already enforces.
- Proof via dogfood (Task 9, `always_allow`).

### Task 8: Approval for external MCP tools  **[R3 — new resume branch, NOT the Ruby gate]**
- Freeze the parked `tool_use` with a **`tool_kind` (`ruby | mcp`)**.
- Resume dispatches on `tool_kind`: `ruby` → existing `run_frozen_call!`; `mcp` → **return allow/deny to
  the SDK's permission mechanism; the server executes; result flows back through the normal stream** —
  Ruby never `ApplicationTool.find`s an `mcp__*` tool.
- **Owns the SDK-mechanism decision** (how a parked `canUseTool` resolves on continuation) — pick what
  fits the current `canUseTool`/reconnect flow.
- Tests: an `mcp` frozen call routes to the SDK-allow branch, not `run_frozen_call!`; reject → deny.

### Task 9: Dogfood gate — `dogfood/mcp.rake`
- Real turn, real Claude + sandbox: seed ONE stdio server (echo MCP or Stripe stdio + test key) → agent
  calls `mcp__<name>__*` → session log shows tool_use/result. **`always_allow` first** (no dependency on
  Task 8). A second scenario covers the Task 8 park→approve→server-executes path once it lands.

## Self-review
Spec §3–§10 covered. R1 (Tasks 4/6), R2 (Task 5), R3 (Task 8), R4 (Task 3) each a discrete task. No
`user` axis; no GitHub connector; no silent tool drops. Types consistent: `McpServer::Spec` (1) →
`to_spec` (2) → resolver (4) → budget+materializer (5) → staging (6).
