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

## 1. The non-negotiable: never use the provider's box-wide switch

Daytona exposes `POST /sandbox/{id}/public/true`. It works (verified: anonymous → `200`), and it is
**forbidden here**. It is **sandbox-WIDE**: it opens every port reachable on the box. In a normal
worktree — postgres, a worker, a web server — it would surface all of them, which is precisely the
scoping this ladder exists to guarantee. **The sandbox stays `public: false`, always.**

Scoping must be enforced by something we control. So:

## 2. rbrun owns the public edge

One unauthenticated route reverse-proxies to exactly one `ServiceRun`:

```
GET|POST|PUT|PATCH|DELETE  /p/:token(/*path)   →  Rbrun::PublicPreviewsController#show
```

1. resolve `:token` → `PublicShare`; unknown ⇒ **404** (never "exists but forbidden" — no enumeration).
2. find that share's live `ServiceRun`; not running ⇒ **503**.
3. forward method / path / query / body to `run.url + path`, attaching
   `x-daytona-preview-token: run.token` **server-side**.
4. relay status, headers and body back.

**Why this scopes correctly:** an unshared service has **no route**. Reachability is decided by rbrun's
routing table, not by what a process happens to bind to. Postgres bound to `0.0.0.0` still cannot be
reached, because nothing forwards to it.

The provider preview token is a server-side secret and **must never reach the browser**.

## 3. Model — `Rbrun::PublicShare`

`worktree_id` (FK), `name` (the service name), `token` (unique, indexed), `tenant` (Tenanted, inherited
from the worktree), timestamps. Unique `[worktree_id, name]`.
`Worktree has_many :public_shares, dependent: :destroy`.

**Why a table, when preview is only a boolean.** A share is a *credential with its own lifetime* —
revocable and rotatable. Neither existing table can hold it:
- `RepoService` is **repo-wide**, not bound to a box; a public link must point at one specific box.
- `ServiceRun` is **destroyed on every `repo_services_start`** (the idempotent reset), so a token there
  would die on each restart.

Keyed on `[worktree, name]` it survives restarts and dies only when revoked.

**Token**: `SecureRandom.urlsafe_base64(32)`. Re-sharing after a revoke mints a **new** token, so an old
link is permanently dead. Added to `filter_parameters`.

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
- **`stop_preview` revokes any share** for that service — you cannot be public while not previewed.
- Service stopped/exited ⇒ the share survives; the edge answers **503**. Restarting restores it (the link
  is stable across restarts, which is the point of keying on `[worktree, name]`).
- Worktree destroyed ⇒ shares destroyed.

## 6. UI

In the Services panel, per service: `[Preview]` → once previewed, `[Open ↗]` `[Share publicly]`; once
shared, the public URL (with copy) and `[Stop sharing]`. A shared service is visually marked — public
exposure must never be quiet.

## 7. Security

- `/p/:token` is the **only** unauthenticated endpoint in the engine (explicit `skip_before_action`).
- Unknown/revoked token ⇒ 404, indistinguishable from never-existed.
- The provider token is attached server-side only.
- No path can address another port: we forward solely to that one run's URL, and the incoming path is
  appended to it (never used to re-target a host).
- The sandbox is never made provider-public.

## 8. Known limitations (v1, stated not buried)

- **WebSockets / ActionCable do not traverse a plain HTTP forward** — Turbo Streams over cable are dead
  through a public link. Needs explicit upgrade handling; out of scope here.
- rbrun must itself be publicly reachable for the link to work; traffic and latency flow through it.
- Long-lived streaming responses need `ActionController::Live` care; v1 buffers.
- No rate limiting or abuse controls.

## 9. Wiring summary

`Rbrun::PublicShare` model + migration + `Worktree has_many`; `ServiceLauncher#share_public` /
`#stop_sharing` (+ the `stop_preview` cascade); `Rbrun::Tools::SharePublic` (`needs_approval!`) +
`Rbrun::Tools::StopSharing`, registered as built-ins + the share gate card;
`Rbrun::PublicPreviewsController` + the `/p/:token(/*path)` route (unauthenticated);
panel actions + the shared-state badge; `ServiceConventions` updated to teach the ladder.

## 10. Dogfood (the gate)

Extend `preview_daytona` with a **phase 3**, proving the scoping on a real box with postgres + jobs +
rails running:
- `share_public("web")` (approved via the gate) ⇒ a public URL.
- **anonymous, no cookies, no provider account** ⇒ the URL serves the Rails app (`200`).
- the **box itself is still private**: the raw Daytona preview URL, fetched anonymously, still terminates
  at the provider login.
- **postgres and jobs have no public route** — assert no share exists for them and that they are not
  reachable through the edge.
- `stop_sharing("web")` ⇒ the same URL now **404s**.
- `stop_preview("web")` ⇒ cascades, any share revoked.
