# Idempotent Turn — `.claude` History Snapshot Design

**Goal:** Make a turn truly idempotent. A turn must not depend on a specific live sandbox: run it against a
lost or fresh box and it reconstructs the box, restores the SDK's resume state, and continues to the same
result. The box becomes **reconstructible, not precious** — invariant #11 at the turn level.

## The insight

The Claude Agent SDK runs as `client.ts` inside the box (invariant #4) with
`CLAUDE_CONFIG_DIR = <workspace>/.claude`, so the conversation's resume history lives at
`<workspace>/.claude` **in the box** — and dies with the box. Everything else a turn needs is already
durable or regenerated:

- **Code** — a git worktree the agent commits + pushes; a lost box re-clones via `Worktree#provision!`.
- **Skills + settings** — re-staged into `.claude/` by `AgentTurn#call_client` on every turn.

So the *only* irreplaceable, non-durable state is the box's `.claude` dir. We snapshot the **whole** dir
(echoing insitix's whole-workspace backup, narrowed to `.claude` because rbrun's code is already in git).
Snapshotting the whole dir rather than a hand-picked subset means we never depend on where the SDK keeps
its resume state.

## Ownership (invariants #2, #9)

The **engine owns the snapshot**. The pure `rbrun-sandbox` gem stays snapshot-agnostic — it offers only
`exec!` / `read` / `write` / `exist?` / `workspace`. The model and the backup/restore orchestration live in
the engine (`app/`), driving those primitives. Sandbox-agnostic by construction, so the Local backend
exercises it in tests with no cloud.

## Durable store — `rbrun_session_snapshots`

A dedicated table in the engine's own DB (invariant #8), one row per session, upserted each turn. Mirrors
the existing `rbrun_skill_versions.archive` binary-blob precedent. `.claude` history is small jsonl, so a DB
blob is right; no object store / new dependency.

Columns: `session_id` (FK, unique), tenant slug (Tenanted, NOT NULL), `data` (binary — the `.tgz`),
timestamps. Model `Rbrun::SessionSnapshot < ApplicationRecord`, `belongs_to :session`, `include Tenanted`,
tenant inherited from the session.

## Orchestration — `Rbrun::ClaudeSnapshot`

Engine service, constructed from a session; drives `session.sandbox`. Snapshots the **whole** `.claude`
dir — not a hand-picked subset — so we never have to know where the SDK keeps resume state; whatever it
wrote comes back. (`.claude/skills` rides along; it's a few KB of markdown and gets overwritten by the fresh
stage anyway — the insitix `node_modules` exclude doesn't transfer, since that's hundreds of MB truly
rebuilt by `bun install`.)

- **`capture!`** (after a turn): `return` unless `<workspace>/.claude` exists; `tar czf … -C .claude .`;
  `read` the tar; upsert the `SessionSnapshot`. **Best-effort** — a failure is logged, never raised (the
  answer already streamed).
- **`restore_if_lost!`** (before a turn): `return` unless a snapshot exists **and** the box has no `.claude`
  at all. Restore runs *before* the runtime stages skills, so a box that still carries `.claude` is a LIVE
  box → no-op; absence = fresh/lost box → `write` the tar and `tar xzf` it into `.claude`. Best-effort.

The `.claude`-presence guard is load-bearing: restoring over a live box's *newer* history would corrupt the
conversation. Restore fires only on a genuinely fresh box, gated by snapshot presence (so the first-ever
turn — no snapshot — is a clean no-op).

## Seam — `AgentTurn#call_client`

The single chokepoint every turn funnels through (`run` / `continue` / `resume`):

```ruby
def call_client(prompt)
  runtime = @runtime || Rbrun.runtime(tenant: @session.tenant, sandbox: @session.sandbox)
  Rbrun::ClaudeSnapshot.new(@session).restore_if_lost!   # reconstruct .claude on a lost box, before resume
  skills_dir = materialize_skills
  runtime.run(…, resume: @session.sdk_session_id, …)
ensure
  FileUtils.remove_entry(skills_dir) if skills_dir && Dir.exist?(skills_dir)
  Rbrun::ClaudeSnapshot.new(@session).capture!           # snapshot .claude after the turn (best-effort)
end
```

Restore runs after the sandbox is resolved and before `runtime.run` (so resume sees the history). Snapshot
runs in `ensure`, synchronously — the dir is small, the user has already seen the streamed answer, and sync
**guarantees the snapshot lands before any reap** (`archive!`, dogfood teardown), leaving no lost-last-turn
window. (Async job later if it ever drags.)

## Consequence — teardown proves it

`agent_deploy` reverts to reaping its dev sandbox in `ensure` (the "keep the box alive" hack is deleted).
`agent_teardown` resumes the SAME session; the box is gone; `restore_if_lost!` reconstructs `.claude` on a
fresh box; the SDK resumes; the agent calls `teardown_deploy` itself. The idempotent turn IS the mechanism
that lets teardown reuse the session without a babysat box.

## Tests (real code, Local backend — no stubs)

- **Model:** tenant inherited from session; one-per-session upsert (second `capture!` updates, never a 2nd row).
- **Service (`ClaudeSnapshot`):** write `.claude/projects/x.jsonl` in a Local box → `capture!` stores a
  non-empty blob; delete `.claude` (simulate box loss) → `restore_if_lost!` brings the WHOLE dir back
  (history, settings, skills); with `.claude` present → `restore_if_lost!` is a no-op (live box not
  clobbered); the transfer tar is cleaned up, never left in the workspace.
- **AgentTurn wiring:** a turn with a scripted runtime still no-ops cleanly (no `.claude` → no capture),
  proving the hooks never break an offline turn.
