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

**ONE DNS record PER SHARED PREVIEW — created on expose, deleted on stop.** Not a wildcard: `*-preview.rb.run`
is a partial-label wildcard Cloudflare DNS does not accept (only `*.rb.run`), and per-host records are what
make enforcement real (a service with no record has no host) and revocation a true DNS deletion. Each host
CNAMEs at **`preview_target` — the rbrun app's own public origin** (e.g. `dev1.rb.run`), NOT a tunnel: the
app is already internet-reachable (users load its UI), so a preview needs no new ingress, only a DNS name
that lands back on the app. Cloudflare is purely DNS + edge TLS on the single label. Lifecycle:

- **expose** (`preview_service`) upserts `<token>-preview.<preview_domain>` → `preview_target` (idempotent).
- **stop** (`stop_preview`) deletes it. Revocation is a real DNS deletion, not just a DB flag.
- A **sentinel** background job reconciles leftovers (a record whose exposure is gone → delete) — a safety
  net for a missed/aborted revocation, NOT the primary mechanism. Per invariant #11, the lifecycle is
  idempotent by construction (upsert on, delete off); the sentinel only sweeps escapes.

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
- `#list(type: nil, name_suffix: nil)` → `[Record]` (pages the whole zone; the suffix filter is
  applied client-side, so it is adapter-portable). The Sentinel uses this to see what actually exists at
  the edge.

Engine side: `Rbrun.dns(provider = nil, tenant: nil)` beside `Rbrun.sandbox`/`Rbrun.runtime`, reading the
`dns_provider` family hash (the `dns` slot already exists in `Config::FAMILIES`).

**This exists for users to put their own domain on their previews.** We happen to be one such user.

## 3. Config

```ruby
c.dns_provider    = { default: :cloudflare, cloudflare: { api_token:, zone_id: } }
c.preview_domain  = "rb.run"          # hosts are <token>-preview.<preview_domain>
c.preview_target  = "app.rb.run"      # THE RBRUN APP'S OWN PUBLIC ORIGIN — preview hosts CNAME here
c.preview_max_sockets = 5             # concurrent hijacked upgrades; see §5
```

There is **no boot-time DNS**. Records are per-share (§1): `PreviewDomain.expose!(token)` on `preview_service`,
`PreviewDomain.unexpose!(token)` on `stop_preview`. Both no-op when `preview_domain`/`preview_target` are
unset (previews simply unavailable) or when the host owns the edge (§6).

## 3a. The Sentinel — reconcile the edge to the DB

The DB (`ServiceExposure`) is the source of truth for **intent**; the DNS record is a **projection** of it.
The per-share lifecycle keeps them in step and is idempotent by construction — but a projection can drift
(a `remove` that failed mid-flight, a process killed between the DB write and the DNS call). Nothing reads
DNS to decide state, so drift is a silent **leak**, never a false "exposed". The Sentinel closes the gap.

`Rbrun::PreviewSentinel.reconcile!` recomputes the desired set from the DB and forces the edge to match:

- **Desired** = every `previewed` exposure carrying a token → `<token>-preview.<domain>`, across ALL tenants
  (the edge is global; the query is unscoped).
- **Actual** = `dns.list(type: "CNAME", name_suffix: "-preview.<domain>")`.
- **Reap** every actual host not desired (an escaped revocation). **Restore** every desired host missing a
  record (an escaped exposure). Matched hosts are untouched.
- No-ops when the host owns the edge (`Rbrun.preview_edge`) or DNS is unconfigured.

`Rbrun::PreviewSentinelJob` is the thin enqueuable wrapper. **Cadence is the host's** — an engine does not
own a scheduler; the host wires it into its recurring runner (e.g. a solid_queue `recurring.yml` entry).
Because the whole thing is idempotent, running it more often only costs API calls; running it never only
lets a leaked record linger.

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

- **unset** (self-host): the engine owns exposure — creates the per-share record, serves the proxy, returns
  its own hostname.
- **set** (control plane): the engine creates **no** DNS record and serves **no** proxy. It asks the host
  to `expose`/`revoke` and stores the returned URL. The control plane's edge (a Worker, at their scale)
  owns the data path; the engine never learns Workers exist.

An object rather than a lambda because revocation is part of the contract, not an afterthought.

## 7. `bin/setup` — dev only, WEBHOOKS ONLY

Standalone, idempotent, **not a product feature and not a `rbrun-dns` consumer**: find-or-create the
Cloudflare tunnel by name → `PUT` its ingress config → upsert the CNAME → `GET …/token` → print
`TUNNEL_TOKEN`. It exists for exactly ONE reason: so **inbound Daytona webhooks can reach a dev laptop**.
It has **nothing to do with previews** — previews never traverse a tunnel; they resolve, via DNS, straight
to the app's own public origin (§1). Conflating the two is the mistake this heading exists to prevent.
Stores nothing; the token is always re-fetched.

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
