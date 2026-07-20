# Sandbox Previews — Design

> Feature spec. Expose a web server running *inside* a sandbox as a viewable preview, driven from the
> UI. Executed on `main`. An **optional, per-provider capability** — Daytona provides it, a proxy-less
> provider does not — surfaced without breaking the multi-provider boundary.

## 0. What it is

A **preview** makes a server running inside the worktree's sandbox (a dev server on `:3000`, an API on
`:8000`) viewable from the browser. rbrun **owns the process**: it starts the command as a managed
process in the sandbox, resolves the provider's public URL for the port, and surfaces a persistent,
worktree-scoped panel — `label :port ● status [Open ↗] [Logs] [Stop]`. Because rbrun holds the process
handle, **status is real** (live/exited) and **logs are tailable**.

A preview is **worktree state**: it belongs to the `Worktree` (which owns the sandbox), so every Session
under that worktree sees the same previews. It is created two ways, through **one launcher**:
- the agent, via a **`needs_approval!`** tool (`run_preview`) — proposed, user-approved, then launched;
- the user, via a **manual control** on the panel — user-initiated, so no gate.

## 1. The capability boundary (multi-provider)

Previews are **capability-by-method-presence**, matching rbrun's no-registry / constant-lookup ethos —
no marker module, no `supports?` enum, no interface object.

- A sandbox adapter that can publish a port defines `preview_url(port) → Rbrun::Sandbox::PreviewLink`.
  `Daytona` implements it (proxy link); `Local` implements it as `http://localhost:{port}`; a
  proxy-less provider simply **omits the method**.
- The engine probes `sandbox.respond_to?(:preview_url)`. **The method's presence IS the capability.**
- `Worktree#previews_supported? = sandbox.respond_to?(:preview_url)`. The UI renders the panel and the
  manual control only when true; `run_preview` returns an `error(...)` when false. Graceful degrade for
  free — on a proxy-less provider the feature is simply absent.

Note the split: **owning the process** (start / tail / stop) uses `session_exec` + `session_logs_follow`
+ `exec`, which **both** adapters already have. Only the **public URL** is provider-optional. So the
whole feature — process, logs, stop, panel — is exercisable on `Local` (localhost), making it
**testable offline**; only the Daytona proxy URL + token needs live Daytona.

## 2. Data model — `Rbrun::Preview` (worktree-scoped)

- **`Rbrun::Preview`** — `belongs_to :worktree`; `include Rbrun::Tenanted` with its own required
  `tenant` column (invariant #8), inherited from the worktree via `before_validation ... on: :create`,
  exactly like `Session`. `Worktree has_many :previews, dependent: :destroy`. Columns:
  - `label` (e.g. "Vite dev server"), `command` (what we run), `port` (int).
  - `status` — string enum `{ starting, live, exited, stopped }`, prefix `:status`.
  - `url` (the resolved preview URL), `token` (the auth token; may be nil for public/localhost).
  - `process_session` (the sandbox process-session id we run it under, e.g. `"preview-<id>"`),
    `cmd_id` (the process-session command handle — for status + log tail + stop-by-pidfile),
    `log_offset` (bytes already streamed, so a re-opened Logs drawer resumes).
  - timestamps.
  - `for_worktree` scope; validations: `command`, `port` present, `port` in 1..65535.

## 3. One launcher, two triggers

`Rbrun::PreviewLauncher` (a service; no logic duplicated between the tool and the controller — the same
discipline as the gate work). `PreviewLauncher.new(worktree:).launch(command:, port:, label:)`:

1. Fail fast unless `worktree.previews_supported?` → returns an error result otherwise.
2. Create the `Preview` (status `starting`) so the panel shows it immediately (broadcast).
3. Start the command as a managed process session in the sandbox, wrapped so it is **stoppable by
   pidfile** and independent of the shell:
   `sh -c 'mkdir -p .rbrun && echo $$ > .rbrun/preview-<id>.pid; exec <command>'`
   via `sandbox.session_create("preview-<id>")` + `sandbox.session_exec(...)` → store `cmd_id`.
4. Resolve `sandbox.preview_url(port)` → store `url` + `token`; mark `live`; broadcast the panel row.
5. Return the preview.

- **Agent trigger:** `Rbrun::Tools::RunPreview` (`needs_approval!`) — `execute(command:, port:, label: nil)`
  calls the launcher. Gated: the frozen call runs on approval via `ApprovalsController → decide_approval!
  → run_frozen_call!` (the existing yes/no path). Its validation card shows the proposed command + port.
- **Manual trigger:** `PreviewsController#create` (worktree-scoped) → the **same** launcher. User-initiated
  ⇒ no gate.

## 4. Process ownership: status, logs, stop

- **Status.** `live` at launch; `stopped` on Stop. `exited` is detected on demand — a **Recheck**
  affordance (and page-load) probes `sandbox.session_command(process_session, cmd_id)`: a present
  `exitCode` ⇒ `exited`. (A background poller that flips `live→exited` proactively is a later
  enhancement; v1 detects on load/recheck/stop and broadcasts.)
- **Logs.** The **Logs** drawer streams the process output live. Opening it enqueues
  `Rbrun::PreviewLogTailJob(preview_id)`, which follows `sandbox.session_logs_follow(process_session,
  cmd_id, skip: log_offset, timeout: WINDOW)` and Turbo-appends chunks to `#preview_<id>_logs`, updating
  `log_offset` as it goes. The follow runs a **bounded window** (a dev server never exits, so an
  unbounded follow would run forever); re-opening resumes from `log_offset`. Same transport the agent
  turn already streams on.
- **Stop.** `PreviewsController#destroy` (and an agent could ask) execs
  `kill $(cat .rbrun/preview-<id>.pid)` in the sandbox (plain `exec`, universal to both adapters — no new
  sandbox-contract method), marks the preview `stopped`, broadcasts. Idempotent.

## 5. The sandbox seam (pure gem)

- **`Rbrun::Sandbox::PreviewLink = Data.define(:url, :token)`** — a gem value object beside `ExecResult`.
- **`Daytona#preview_url(port)`** → `Client#preview_link(id, port)` → `PreviewLink`. The client GETs
  Daytona's preview endpoint for `(sandbox id, port)` and returns `{ url, token }`. **The exact endpoint
  path + token-carrying mechanism is verified against the live API in the dogfood** (§7).
- **`Local#preview_url(port)`** → `PreviewLink.new(url: "http://localhost:#{port}", token: nil)`. Makes
  the feature real offline (the process genuinely listens on the host), so the dogfood needs no cloud.
- A proxy-less adapter defines neither — and is correctly treated as preview-incapable.

## 6. UI

- **Sidebar panel** — a section in `app/views/layouts/rbrun/application.html.erb`, directly under the
  repo switcher, rendered for the **current worktree** (the conversation's `@session.worktree`; absent on
  pages without one). One row per preview: `● label :port` + `[Open ↗]`, with an overflow `[Logs] [Stop]`.
  A `current_worktree` layout helper mirrors the existing `current_repo` seam.
- **Live updates across sessions.** The layout subscribes to `turbo_stream_from "rbrun_worktree_#{id}"`;
  `Preview` broadcasts row create/replace/remove to that stream, so a preview launched in one session
  appears in every session's sidebar. (Session timelines keep their own `rbrun_session_#{id}` stream.)
- **Open ↗** → `previews/:id/open` (engine endpoint), which 302-redirects to the live app **in a new
  tab** (`target=_blank`), attaching the token the way the provider's proxy accepts it. New-tab avoids
  the iframe token/framing problem entirely.
- **Logs** → a **slide-over drawer** (Stimulus) with a `#preview_<id>_logs` pane the tail job appends to.
- **Manual control** — a small "＋ Preview" affordance in the panel opening a command/port/label form →
  `PreviewsController#create`.

## 7. Security / the token edge — the one real risk

A private Daytona port needs the `x-daytona-preview-token` header; a browser tab/iframe can't set
headers. **All browser access goes through the engine's `previews/:id/open`**, the single seam that
turns a stored `(url, token)` into a browser-openable request — by whichever mechanism Daytona's proxy
actually honors (token query param, or a cookie-setting redirect on the preview domain). **Determining
that mechanism is the #1 dogfood verification** before this is called done; the endpoint isolates the
adaptation to one method. The token is stored server-side and never rendered into page HTML.

## 8. Tools + gate

- `Rbrun::Tools::RunPreview` — `needs_approval!`; params `command` (required), `port` (required, int),
  `label` (optional). `execute` → `PreviewLauncher`. Registered as a built-in in the engine
  `after_initialize` (like the workflow tools). Errors cleanly when `!previews_supported?`.
- Validation card `Rbrun::Sessions::ToolsValidation::RunPreview::Component` — shows command + port + label
  with the shared yes/no `approval_actions`. Optional (falls back to `Default`); not boot-enforced
  (`needs_approval!`, not `custom_approval!`).
- (No new gate mechanics — rides `needs_approval!` / `ApprovalsController`.)

## 9. Wiring summary (this build)

`Rbrun::Preview` model + migration + `Worktree has_many :previews` + `previews_supported?`;
`PreviewLink` value object + `Daytona#preview_url`/`Client#preview_link` + `Local#preview_url`;
`PreviewLauncher`; `RunPreview` tool + card (built-in); `PreviewsController` (create/destroy/open) +
routes + `PreviewLogTailJob`; the sidebar panel + `current_worktree` helper + worktree Turbo stream +
the logs drawer (Stimulus). A **dogfood** (§ below) — unlike workflows, we build one here because the
token path demands live verification.

## 10. Out of scope (v1)

Multiple simultaneous log drawers' persistence after sandbox stop; a proactive `live→exited` poller
(v1 detects on load/recheck/stop); embedding the app in an in-app iframe (new-tab only); editing a
preview after launch; auto-detecting listening ports (the command declares its port). Framing-hostile
apps are simply opened in a tab.

## 11. Dogfood (acceptance gate)

- **`preview_local`** (offline, no cloud): launch a trivial server (`bun`/`python -m http.server`) on a
  port via the launcher, assert the panel row goes `live`, the URL is `http://localhost:PORT` and
  actually serves, Logs tails real output, Stop kills it and flips `stopped`. Proves process-ownership,
  logs, stop, panel, capability probe — end to end, no Daytona.
- **`preview_daytona`** (live, `.env` creds): the same flow on Daytona — **specifically verifies the
  proxy `preview_url` shape and the browser token mechanism** through `previews/:id/open`. This is the
  gate that closes §7's open question.
