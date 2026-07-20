# Public Sharing — Design (exposure ladder, level 3)

> Feature spec. Make **exactly one** running service reachable by anyone with a link — without ever
> opening the sandbox. Level 3 of the exposure ladder (CLAUDE.md invariant #10). Executed on `main`.

## 0. The ladder, and where this sits

1. **Run** — a supervised process inside the box. Exposes nothing. A `port` is only what it binds to
   internally.
2. **Preview** — `preview_service` / `stop_preview`. Resolves a provider URL that **still requires the
   viewer's own provider account**. Ungated.
3. **Public** (this spec) — **anyone with the link, no account.** Gated by `needs_approval!`.

Each step is opt-in, reversible, and **scoped to one service**. A level is never skipped: public requires
previewed.

## 1. Implementation: the provider's own switch

Level 3 uses the sandbox's optional `set_public(enabled)` capability. On Daytona that is
`POST /sandbox/{id}/public/{true|false}` — verified working (anonymous → `200`, no login).

**Granularity gap, accepted explicitly.** Daytona expresses this per **SANDBOX**, not per port: every
externally-bound port becomes reachable at its own `<port>-<sandboxId>` host, and that id is visible in
any link we share. So our per-service `shared_public` flag is **intent**, not enforcement. We accept it
because dev sandboxes are throwaway and their db/queue/worker bind locally — an assumption, not a
guarantee. A provider offering per-port control implements `set_public` honouring the port; nothing
above the adapter changes.

**Why not an rbrun-owned reverse proxy** (the discarded design): serving the app under our own path
prefix breaks its root-relative URLs — assets and JS 404 — and no app-side setting
(`RAILS_RELATIVE_URL_ROOT`) should be required, since rbrun must host any framework. Fixing it properly
needs host-based routing (wildcard DNS + cert), and being in the request path taxes every stream,
upload and websocket forever. Not worth it for a throwaway dev box.

## 2. Reference counting

The provider switch is box-wide, so it is turned **off only when no service remains shared** — revoking
one service must never silently cut another that is still public.

## 3. Model — a flag, not a table

`RepoService#shared_public` (boolean, default false), beside `previewed`. On the **definition**, so it
survives the `repo_services_start` reset, exactly like `previewed`. No table and no token: the public URL
is the provider's own preview URL (`ServiceRun#url`), because rbrun is not in the request path.

## 4. Tools + actions

| Tool | Gate | Effect |
|---|---|---|
| **`share_public(name)`** | **`needs_approval!`** | requires previewed; creates the share, returns the public URL |
| **`stop_sharing(name)`** | ungated | destroys the share — the token dies immediately |

The same two as panel actions. **"Share publicly" only renders when the service is already previewed.**
Revoking is ungated everywhere because withdrawing access is always safe.

The gate card for `share_public` states plainly what is being granted: *this service will be reachable by
anyone with the link, without an account.*

## 5. Cascade rules (a level can never be skipped)

- `share_public` on a service that is not previewed ⇒ error. Level 3 sits on level 2.
- **`stop_preview` revokes the share** for that service — you cannot be public while not previewed.
- `stop_sharing` clears the flag, and flips the provider switch off **only if no other service is still
  shared**.
- Service stopped/exited ⇒ the flag survives; the URL simply stops answering until it runs again.

## 6. UI

In the Services panel, per service: `[Preview]` → once previewed, `[Open ↗]` `[Share publicly]`; once
shared, the globe turns amber and the action flips to `[Stop sharing]`. Public state is shown loudly —
exposure must never be quiet.

## 7. Security posture — stated honestly

- The public URL is the **provider's** preview URL; rbrun is not in the request path and holds no edge.
- **Scoping is intent, not enforcement** (see §1): the provider switch is box-wide, so any other
  externally-bound port on that box is reachable by editing the port in the hostname. Accepted for
  throwaway dev sandboxes; revisit if boxes ever become long-lived or hold real data.
- `share_public` is `needs_approval!` — the agent can never expose anything on its own.
- Revocation is immediate and always available, ungated.

## 8. Known limitations

- The granularity gap in §1/§7.
- Whether a `localhost`-bound service is reachable through the provider proxy is **unverified** — we
  assume not. Untested by choice.
- No rate limiting or abuse controls (the provider owns the edge).

## 9. Wiring summary

`RepoService#shared_public` + migration (drops the old `rbrun_public_shares` table);
`Sandbox#set_public(enabled)` optional capability (`Daytona` → `POST /sandbox/{id}/public/{bool}`,
`Local` → no-op); `ServiceLauncher#share_public` / `#stop_sharing` (+ the `stop_preview` cascade and the
box-wide reference count); `Rbrun::Tools::SharePublic` (`needs_approval!`) + `Rbrun::Tools::StopSharing`
+ the share gate card; panel actions; `ServiceConventions` teaches the ladder.

## 10. Dogfood (the gate)

`preview_daytona` phase 3, on a real box running postgres + jobs + css + rails:
- `share_public("web")` (approved via the gate) ⇒ `shared_public` set, provider switch on.
- **anonymous, no cookies, no provider account** ⇒ the preview URL serves the Rails app (`200`) —
  including its assets, since the app is served at its own root by the provider.
- `stop_sharing("web")` ⇒ anonymous access returns to the provider login.
- `stop_preview("web")` ⇒ cascades: the share is revoked too.
