# Repo Services — Design

> Feature spec. Give the agent a sanctioned way to run a repo's long-lived **services** (web, worker,
> redis, db…) inside the worktree's sandbox, so **rbrun captures their state** and renders it — status,
> logs, and (for HTTP services) a **preview** URL. Executed on `main`.

## 0. What it is

A repo runs on several **services** — `bin/rails s`, `bin/vite dev`, `bundle exec sidekiq`,
`redis-server`, `postgres`. The agent can already start these with raw shell; the point of this feature
is **soft instrumentation**: a small tool contract the agent is *instructed* to use for long-lived
processes, so rbrun holds each one's process handle and can show **status + logs**, and — for a service
that listens on an HTTP port — a **preview** the user opens in a tab. A service *happens to be
previewable*; preview is a facet, not the primary thing.

Two layers, mirroring the workflows design:
- **The run** (live, worktree-scoped): what's running now — status, logs, previews.
- **The library** (saved, per-repo): the repo's declared services, reusable — "restart all" re-launches
  the set in a fresh sandbox.

**The supervision mechanism is a swappable backend.** v1 supervises via managed sandbox
process-sessions + pidfiles; systemd units or docker-compose could implement the *same five tools* later
without changing one thing the agent sees. The tool contract is the seam.

## 1. The tool contract (the foundation everything builds on)

Five tools, the compose/foreman verb set. Registered as engine built-ins (like the workflow tools).
Only `repo_services_start` is gated. Results are string-keyed (`{ "data" => … }` / `{ "error" => … }`).

| Tool | Params | Gate | Semantics |
|---|---|---|---|
| **`repo_services_start`** | `services: [{name, command, port?}]` | **`needs_approval!`** — one gate for the whole set | **Idempotent reset** ("kill all and restart"): stop every service running in this worktree, then start the declared set fresh. **Upserts** the set as the repo's saved services. Resolves the preview URL for each port-bearing service. |
| **`repo_services_restart`** | `name:` | ungated | Surgical stuck-recovery: kill that one + start it again from its saved command. |
| **`repo_services_stop`** | `name:` (omit ⇒ all) | ungated | Stop one, or all, in this worktree. |
| **`repo_services_status`** | — | ungated (read) | Each service `{ name, command, port, status, url }` — so **the agent knows** what's running / exited / stuck, the same truth rbrun renders. |
| **`repo_services_logs`** | `name:`, `tail: 200` | ungated (read) | The **debug** primitive — recent output of one service. |

- **Idempotency is structural.** `start` = tear-down-then-bring-up (predictable reset, no "already
  running" branch); `restart(name)` = kick one stuck service. Re-running either always converges. This
  is the answer to "processes get stuck / shit restarts": the agent (and a user button) can always reset
  to a known state.
- **Only `start` is gated** — it launches new commands (one approval for the set). Restart/stop/status/
  logs are control+read on already-approved services, so they stay ungated (frictionless recovery).

## 2. Soft convention — the system prompt

The tools are not a cage: the agent *can* background anything. It uses them because the **main agent
system prompt instructs it to**, and because it gets logs+status back. The engine appends a
service-conventions block to the turn's system prompt — in `Rbrun::AgentTurn#call_client`, `system:
[Rbrun.config(tenant).system_prompt, Rbrun::ServiceConventions::PROMPT].join("\n\n")` — so it applies
regardless of the host's base prompt. The block says, in substance:

> For any **long-lived** process — dev servers, workers, databases, queues, anything that keeps running
> — use `repo_services_start` (and `repo_services_restart` / `stop` / `status` / `logs`), never a raw
> `&` / `nohup`. This makes it visible to the user, previewable if it serves HTTP, and debuggable via
> its logs. Use normal command execution only for **one-shot** commands (build, test, migrate). If a
> service is stuck, `repo_services_restart` it; to reset everything, `repo_services_start` again.

## 3. Data model (two layers)

### `Rbrun::RepoService` — the saved definition (library)

Tenant-scoped, per repo. `include Rbrun::Tenanted` (own `tenant` column, invariant #8). Columns:
`tenant`, `repo`, `name`, `command`, `port` (nullable int), `position`. Unique `[tenant, repo, name]`.
The repo's service set = `RepoService.for_tenant(t).where(repo:).order(:position)`. `repo_services_start`
upserts these; the panel's **Restart all** reads them.

### `Rbrun::ServiceRun` — a live running service (run)

Worktree-scoped. `belongs_to :worktree`; `include Rbrun::Tenanted` (inherited from the worktree on
create, like `Session`). `Worktree has_many :service_runs, dependent: :destroy`. Columns:
- `name`, `command`, `port` (snapshotted at launch, so a run is self-contained).
- `status` — string enum `{ starting, running, exited, stopped }`, prefix `:status`; `exit_code` (int, nullable).
- `url`, `token` (the preview link for a port-bearing service; nil otherwise or on a proxy-less provider).
- `process_session` (the sandbox process-session id, `"svc-<worktree>-<name>"`), `cmd_id` (the process
  handle — status/logs/stop), `log_offset` (bytes already streamed, so a re-opened Logs drawer resumes).
- timestamps. Unique `[worktree_id, name]`.
- **Previewable** ⇔ `port.present? && url.present?`.

## 4. Supervision (backend-agnostic; v1 = managed sessions + pidfiles)

All four lifecycle ops go through the sandbox transport **both adapters already have** — no new
sandbox-contract method:
- **Launch** (`start` / `restart`): `sandbox.session_create(process_session)` then `session_exec` of
  `sh -c 'cd <workspace> && mkdir -p .rbrun && echo $$ > .rbrun/svc-<name>.pid; exec <command>'` → store
  `cmd_id`, mark `running`. The pidfile makes it stoppable independently of the transport.
- **Stop / kill**: `sandbox.exec("kill $(cat <workspace>/.rbrun/svc-<name>.pid) 2>/dev/null")` (plain
  `exec`, universal), mark `stopped`. Idempotent.
- **Status**: `sandbox.session_command(process_session, cmd_id)` — a present `exitCode` ⇒ `exited`
  (+ `exit_code`). Computed on panel load, on `repo_services_status`, and on a **Recheck**. (A proactive
  `running→exited` poller is a later enhancement.)
- **Logs**: `sandbox.session_logs_follow(process_session, cmd_id, skip: log_offset, timeout: WINDOW)` —
  the same follow transport the agent turn streams on. Bounded window (a dev server never exits);
  re-opening resumes from `log_offset`.

`Rbrun::ServiceSupervisor` (a service object) owns these mechanics so a future systemd/compose backend is
a single swap, and neither the tools nor the UI change.

## 5. Preview = the port facet (multi-provider capability)

The **only** provider-optional piece. Capability-by-method-presence, matching rbrun's no-registry ethos:
- An adapter that can publish a port defines `preview_url(port) → Rbrun::Sandbox::PreviewLink(url:,
  token:)`. `Daytona` implements it (proxy link, via `Client#preview_link`); `Local` implements it as
  `http://localhost:{port}`; a proxy-less provider **omits** it.
- `Worktree#previews_supported? = sandbox.respond_to?(:preview_url)`. At launch, a port-bearing service
  resolves `preview_url(port)` → stores `url` + `token` **only when supported**; otherwise it still runs
  and logs, just without an `[Open ↗]`. Graceful degrade — the presence of the method IS the capability.
- **`Rbrun::Sandbox::PreviewLink = Data.define(:url, :token)`** — a gem value object beside `ExecResult`.

Because launch/logs/stop use transport both adapters have, the whole feature is **exercisable on
`Local`** (localhost) — testable offline; only Daytona's proxy URL + token needs the cloud.

## 6. UI — the Services panel

- **Sidebar panel** under the repo switcher in `app/views/layouts/rbrun/application.html.erb`, for the
  **current worktree** (`@session.worktree`; absent on pages without one — a `current_worktree` layout
  helper mirrors `current_repo`). One row per live `ServiceRun`: `● name :port? status`, with `[Logs]`,
  `[Stop]`, `[Restart]`, and — when previewable — `[Open ↗]`. When nothing runs but the repo has saved
  services: a **Restart all** button (re-runs the saved set — ungated, already-approved commands).
- **Live across sessions.** The layout subscribes to `turbo_stream_from "rbrun_worktree_#{id}"`;
  `ServiceRun` broadcasts row create/replace/remove there, so a service started in one session appears in
  every session's sidebar. (Session timelines keep their `rbrun_session_#{id}` stream.)
- **Open ↗** → `services/:id/open` (engine endpoint) 302-redirects to the live app **in a new tab**,
  attaching the token the provider's proxy accepts. New-tab sidesteps the iframe header/framing problem.
- **Logs** → a **slide-over drawer** (Stimulus) with a `#service_<id>_logs` pane a
  `Rbrun::ServiceLogTailJob` appends to.
- **Manual operation** = the panel's own buttons (Restart / Stop / Restart all / Open / Logs), all
  user-driven and ungated. **Defining** the service set is the agent's gated `repo_services_start` (or
  Restart-all of the saved set). No separate manual "define services" form in v1.

## 7. Security — the token edge (the one live-verify item)

A private Daytona port needs the `x-daytona-preview-token` header, which a browser tab can't set. **All
browser access goes through `services/:id/open`** — the single seam that turns a stored `(url, token)`
into a browser-openable request, by whichever mechanism Daytona's proxy honors (token query param, or a
cookie-setting redirect on the preview domain). **Determining that mechanism is the #1 dogfood
verification.** The token is stored server-side, never rendered into page HTML.

## 8. Wiring summary (this build)

`Rbrun::RepoService` + `Rbrun::ServiceRun` models + migration + `Worktree has_many :service_runs` +
`previews_supported?`; `PreviewLink` value object + `Daytona#preview_url`/`Client#preview_link` +
`Local#preview_url`; `Rbrun::ServiceSupervisor` + `Rbrun::ServiceLauncher`; the five `repo_services_*`
tools (built-ins) + the `repo_services_start` gate card; `Rbrun::ServiceConventions::PROMPT` +
its append in `AgentTurn`; `ServicesController` (open/stop/restart/restart_all) + routes +
`ServiceLogTailJob`; the sidebar Services panel + `current_worktree` helper + worktree Turbo stream +
the logs drawer (Stimulus). No new gate mechanics — `repo_services_start` rides `needs_approval!` /
`ApprovalsController`.

## 9. Out of scope (v1)

A proactive `running→exited` poller (v1 detects on load/recheck/status); in-app iframe embedding
(new-tab only); a manual "define arbitrary service" UI form (the agent tool + Restart-all cover it);
service dependency ordering (start in parallel — apps retry-connect); systemd/compose supervision
backends (the tool contract is built to allow them, they aren't built now); log persistence after the
sandbox is torn down (live tail only).

## 10. Dogfoods (acceptance gate)

- **`repo_services_local`** (offline, no cloud): `repo_services_start` a trivial HTTP server
  (`python -m http.server` / a `bun` one-liner) plus a non-HTTP "worker"; assert the panel rows go
  `running`, the HTTP one's `url` is `http://localhost:PORT` and actually serves, `repo_services_logs`
  tails real output, `repo_services_restart` re-launches a stuck one, `repo_services_stop` kills it and
  flips `stopped`, and a second `repo_services_start` is idempotent (kill-all + fresh). Proves the tool
  contract, supervision, idempotency, logs, status, and the preview facet end-to-end — no Daytona.
- **`preview_daytona`** (live, `.env` creds — present): the HTTP path on Daytona, **specifically
  verifying the proxy `preview_url` shape and the browser token mechanism** through `services/:id/open`.
  This closes §7's open question.
