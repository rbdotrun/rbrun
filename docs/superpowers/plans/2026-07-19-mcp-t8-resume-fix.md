# M-T8 — external MCP approval RESUME: diagnosis + fix (handoff)

**From:** the control-plane effort. **For:** whoever owns `client.ts`/the runtime.
**Status:** park half proven live; resume half implemented, not working live. This is the fix.

Ship `always_allow` MCP now (dogfooded, both sides). Land this as the next PR — it does **not** block
the merge.

---

## Why it's broken (the asymmetry, not a mess)

The Ruby-tool gate works because **Ruby owns execution**: on approval `run_frozen_call!` runs the tool
and *injects the result* — the SDK never re-attempts. An external `mcp__*` tool is **SDK-owned**, so
resume means the **model must re-attempt** the call. Teardown-and-resume (deliberate: "approvals never
come back to a running process") is right for Ruby tools and fights SDK-owned tools. Two failure modes
fall out:

1. **Cold-start race** — a fresh `client.ts` on resume re-spawns `bunx …/server-everything`; the model
   acts before the stdio handshake lands → "tool unavailable", or the model doesn't call it at all
   (non-deterministic).
2. **Stale denial in history** — the parked `canUseTool` deny sits in the resumed transcript, so the
   model concludes a **permanent rejection** ("the earlier attempt was rejected") and won't re-issue.

The `approved[]` set is Ruby-correct (the name IS force-allowed on resume). The breakage is entirely on
the SDK/server side of resume.

## The fix — three additive changes, in priority order

### 1a. Pre-warm the server package during staging  *(kills the race at the source)*
When staging the sandbox (same place skills/`bun install` happen), warm the MCP package cache once —
e.g. `bun install @modelcontextprotocol/server-everything` (or a `bunx --help`-style prefetch per
declared stdio server). Then the resume re-spawn is instant from cache, not a cold `bunx` download.
Materialized `mcp.json` already lists the servers — iterate its stdio commands.

### 1b. Readiness gate  *(makes it deterministic, retryable)*
Lift `_nvoi`'s `Sandboxes::Agent::McpReadiness`: `required` = every server in the materialized
`mcp.json`; `preflight!` (fail closed if the lib can't report status) / `observe` (accumulate latest
per-server status from the stream) / `verify_seen!` (a run that required servers but saw no handshake is
unverified; a settled `failed`/`needs-auth` or absent server fails closed; **tolerate `pending`** — the
SDK reports status once at init and a `pending` server often still serves calls). Wire it into the turn
so "silently ran without the tool" becomes a loud, retryable failure instead of a false green.

### 2. Neutral deny + affirmative, tool-specific resume nudge  *(fixes "reported rejected")*
- On park, have `canUseTool` deny with a **neutral** reason — "paused for owner approval; you will be
  told to proceed" — **not** "rejected".
- On resume, inject a **tool-specific, affirmative** nudge before handing back control:
  *"Your `mcp__<srv>__<tool>` call was APPROVED. Call it again now with the same arguments."* This
  overrides the stale denial so the model re-issues instead of narrating the rejection. (The Ruby-tool
  resume nudge is generic; external tools need the explicit "approved, call it again".)

## If 1a+1b+2 still flake: the clean alternative
Make `canUseTool` **async (keep-alive)** for external tools only — return a Promise that resolves on
approval, so the run stays alive, the server stays connected, and there is no resume/reconnect/
denial-in-history at all. It eliminates the whole failure class but breaks the "gate ends the run"
invariant (a long-lived detached process awaiting approval). Bound it with a timeout that falls back to
teardown-park. Only reach for this if the re-attempt path stays unreliable.

## Verification (extend `dogfood/mcp.rake`)
Second scenario, `needs_approval`: park (✓ already) → approve → **the same server re-connects and the
tool round-trips on resume** (reply carries the marker). Green = T8 done.

## Control-plane note
Nothing changes on the control-plane side: `WorkspaceMcp.tool_permissions` already carries
`needs_approval`, and the resolver ships it in the Spec. When resume works, gated external tools park in
the existing approval UI and resume — no CP change needed.
