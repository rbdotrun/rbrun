# Preview Edge — Design (DNS capability + the engine's own proxy)

> Feature spec. Give the engine its own preview edge: a **DNS capability** so users can put their own
> domain on previews, and a **Worker-less proxy** that serves levels 2 and 3 under that domain. Replaces
> the provider's box-wide public switch. Executed on `main`.
>
> **Out of scope, own spec:** webhook registration + reconciliation. This spec only builds the dev tunnel
> those will also need.

## 0. Why this replaces what we shipped hours ago

Level 3 currently flips Daytona's `public` flag. It works, but it is **box-wide** — our per-service flag
is intent, not enforcement — and it drags Daytona's own interstitial and account model in front of the
user's app. Owning the edge fixes all three at once:

- **Per-service enforcement is real**: only a shared service has a route. A port that isn't shared has no
  address, whatever it binds to.
- **The sandbox is never made provider-public.** We hold the preview token server-side.
- **Level 2 becomes ours too**: viewing a private preview needs an **rbrun** session, not a Daytona
  account — so a teammate without a Daytona login can be given access.

Cost, accepted: every byte flows through the host app. In self-host the operator *is* the tenant, so this
is their capacity decision, not a defect. The control plane bypasses it (§6).

**CLAUDE.md invariant #10 flips back** — the "never proxy / use the provider switch" wording was written
for the previous design and must be corrected, not left contradicting the code. Third rewrite of that
invariant; the churn is real and worth naming.

## 1. Hostnames — single label, free certificate

Universal SSL covers the apex and **first-level only**. `*.preview.rb.run` would need Total TLS /
Advanced Certificate Manager (paid). So every preview host is a **single label**:

```
<share-token>-preview.<preview_domain>     e.g. k3f9x2-preview.rb.run
```

Verified against Cloudflare docs, and consistent with `_nvoi` ("the worker rides the zone's Universal SSL
wildcard cert").

**ONE wildcard DNS record, not one per share.** `*.<preview_domain>` → the rbrun host, created once and
idempotently. Per-share records would mean per-share cleanup, and a leaked record on every missed
revocation. With a wildcard there is nothing to clean up: revocation is a DB row, and an unknown host
404s.

## 1a. A preview host resolves to EXACTLY ONE sandbox's service

`<token>-preview.<domain>` must address one deterministic running service — one worktree's sandbox, one
port. Never "guess the most recent."

The addressing token therefore lives on a **per-`[worktree, name]`** record, `Rbrun::ServiceExposure`:

- `belongs_to :worktree`; Tenanted (inherited); columns `name`, `preview_token` (unique, single-label),
  `previewed`, `shared_public`. Unique `[worktree_id, name]`.
- **Survives the `repo_services_start` reset** — only `ServiceRun` is destroyed, not this — so a shared
  link never rotates. It is the stable per-worktree home the token needs, which neither `RepoService`
  (repo-level) nor `ServiceRun` (ephemeral) provides.
- Resolution: `token → ServiceExposure → worktree → service_runs.find_by(name:, status: "running")`.
  Exactly one sandbox. No cross-worktree ambiguity.

The intent flags **move here from `RepoService`**: `previewed`/`shared_public` are per-worktree decisions
(previewing `web` on branch A must not expose branch B), not repo-wide ones. `RepoService` goes back to
being just the saved command set.

## 2. `rbrun-dns` — the capability (product, for our users)

A pure gem beside `rbrun-sandbox`, same idioms: constant-lookup adapters, no registry, adapter validates
its own credentials and fails fast, all HTTP via Faraday on `async-http`.

```ruby
Rbrun::Dns.new(provider: :cloudflare, config: { api_token:, zone_id: })
```

- `ADAPTERS = { cloudflare: "Cloudflare" }` — `route53` slots in later with no caller change.
- `Rbrun::Dns::Record = Data.define(:id, :name, :type, :content, :proxied)`
- `#upsert(name:, type:, content:, proxied: false)` → `Record` (find-then-create/patch; idempotent)
- `#find(name:, type: nil)` → `Record | nil`
- `#remove(name:, type: nil)` → `Boolean`

Engine side: `Rbrun.dns(provider = nil, tenant: nil)` beside `Rbrun.sandbox`/`Rbrun.runtime`, reading the
`dns_provider` family hash (the `dns` slot already exists in `Config::FAMILIES`).

**This exists for users to put their own domain on their previews.** We happen to be one such user.

## 3. Config

```ruby
c.dns_provider    = { default: :cloudflare, cloudflare: { api_token:, zone_id: } }
c.preview_domain  = "rb.run"          # hosts are <token>-preview.<preview_domain>
c.preview_target  = "tunnel-id.cfargotunnel.com"  # what the wildcard points at (CNAME)
c.preview_max_sockets = 5             # concurrent hijacked upgrades; see §5
```

`Rbrun::PreviewDomain.ensure!` upserts `*.<preview_domain>` → `preview_target` via the DNS capability.
Idempotent, safe on every boot, no-ops when `preview_domain` is unset (previews simply unavailable).

## 4. The proxy — HTTP

A Rack-level entry point matching on **Host**, ahead of the engine's routes:

1. `Host` → `<token>-preview.…` → resolve the share; unknown ⇒ **404** (indistinguishable from revoked).
2. Not running ⇒ **503** (a wait/started page is a later concern, see §8).
3. **Level check**: `shared_public?` ⇒ serve anyone. Otherwise require an **rbrun session**; no session ⇒
   redirect to rbrun login.
4. Relay method/path/query/body to `run.url + path`, attaching `x-daytona-preview-token` **server-side**.
5. Relay status/headers/body back, minus hop-by-hop.

The app is at the **root of its own hostname**, so its root-relative `/assets/…` resolve through us with
zero rewriting and zero app-side config (`RAILS_RELATIVE_URL_ROOT` never enters the picture).

## 5. The proxy — WebSockets

**Verified**: one `rack.hijack` implementation behaves identically on **Puma 8.0.2** and **Falcon 0.55.5**
— both return `101` and pass raw bytes bidirectionally. So there is **one implementation**, no
server-specific branch.

- Take the socket via `env["rack.hijack"]`, open TLS upstream, send the upgrade **with our token header**,
  relay the `101`, then **pump bytes — never parse frames**. Byte relay preserves subprotocols,
  `permessage-deflate`, pings and binary frames for free.
- **Concurrency cap** (`preview_max_sockets`), non-negotiable: on Puma each live socket pins a thread
  (default 5/worker), so uncapped upgrades starve the app serving the UI. Past the cap we **refuse the
  upgrade** (`503`) rather than degrade everything.
- On Falcon a connection is a fiber, so the cap can be raised/removed — a config value, not a code path.
- Close the peer on half-close, or we leak sockets *and* threads.

## 6. The bypass seam (the control plane)

Same idiom as `config_resolver` / `mcp_resolver`: set-once host DI.

```ruby
Rbrun.preview_edge = SomeHostEdge.new   # responds to #expose(run) -> url, #revoke(run)
```

- **unset** (self-host): the engine owns exposure — ensures the wildcard, serves the proxy, returns its
  own hostname.
- **set** (control plane): the engine creates **no** DNS record and serves **no** proxy. It asks the host
  to `expose`/`revoke` and stores the returned URL. The control plane's edge (a Worker, at their scale)
  owns the data path; the engine never learns Workers exist.

An object rather than a lambda because revocation is part of the contract, not an afterthought.

## 7. `bin/setup` — dev only

Standalone, idempotent, **not a product feature and not a `rbrun-dns` consumer**: find-or-create the
Cloudflare tunnel by name → `PUT` its ingress config → upsert the CNAME → `GET …/token` → print
`TUNNEL_TOKEN`. It exists so a laptop-hosted rbrun is reachable for previews and (later) webhooks. Stores
nothing; the token is always re-fetched.

## 8. Out of scope (this spec)

Wake-on-request + wait screen (the 503 stays a 503 for now); webhook registration and state
reconciliation (own spec — the stale-`running` problem is real and unfixed); `route53`; rate limiting.

## 9. Dogfood (the gate)

Extend the Daytona dogfood: with `db`/`jobs`/`css`/`web` running,
- `preview_service("web")` ⇒ an **rbrun** hostname; anonymous ⇒ redirected to rbrun login (level 2).
- `share_public("web")` (gated) ⇒ the same hostname serves **anonymously, 200, with assets**.
- `db`/`jobs`/`css` have no route: their hostnames 404 — enforcement, not intent.
- The **Daytona box is never public**: its raw provider URL still terminates at the provider login.
- `stop_sharing` ⇒ anonymous back to login; `stop_preview` ⇒ 404.
