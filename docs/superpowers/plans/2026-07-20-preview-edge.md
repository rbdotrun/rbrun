# Preview Edge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** the engine owns its preview edge — a DNS capability users point their own domain at, and a
Worker-less proxy serving levels 2 and 3 under it. Retires the provider's box-wide public switch.

**Architecture:** `rbrun-dns` (pure gem, constant-lookup adapters) + one wildcard record + a Rack-level
Host-matching proxy (HTTP relay + `rack.hijack` WebSockets, capped) + a set-once host DI seam so the
control plane can own the edge instead.

## Global Constraints

- CLAUDE.md invariants: no registry (constant lookup), adapters validate own config, all outbound HTTP is
  Faraday on `async-http`, every record tenant-scoped.
- **Invariant #10 gets rewritten (third time)** — it currently forbids proxying and mandates the provider
  switch. Code and doc must not disagree at any commit.
- Single-label hosts only (free Universal SSL). ONE wildcard record — never per-share.
- The preview token is attached server-side and never reaches a browser.
- The WS cap is non-negotiable: exceeding it refuses the upgrade, never degrades the app.
- No fakes: gem tested against a stubbed wire (WebMock), engine against real objects.
- Tests + `bin/rubocop` green per task. Work on `main`.

---

### Task 1: `gems/rbrun-dns` — the capability

**Files:** `gems/rbrun-dns/{rbrun-dns.gemspec,Rakefile,README.md}`,
`lib/rbrun/dns.rb`, `lib/rbrun/dns/{version,record,cloudflare}.rb`,
`test/{test_helper.rb,rbrun/dns/{dns_test,cloudflare_test}.rb}`

**Produces:** `Rbrun::Dns.new(provider:, config:)`; `Record`; `Cloudflare#upsert/find/remove`.

- [ ] **Step 1** family entry, mirroring `Rbrun::Sandbox`:

```ruby
module Rbrun
  module Dns
    class Error < StandardError; end
    ADAPTERS = { cloudflare: "Cloudflare" }.freeze

    def self.new(provider:, config: {}, **opts)
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown dns provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(config: config, **opts)
    end
  end
end
```

- [ ] **Step 2** `Record = Data.define(:id, :name, :type, :content, :proxied)`.
- [ ] **Step 3** `Cloudflare` — Faraday on `:async_http`; fails fast without `api_token`/`zone_id`.
  `#find` → `GET /zones/{zone}/dns_records?name=&type=`; `#upsert` → find then `POST` or `PATCH`
  (`/zones/{zone}/dns_records[/{id}]`); `#remove` → `DELETE`. All return `Record`/bool.
- [ ] **Step 4** tests via WebMock against the real adapter: create-when-absent, patch-when-present
  (assert it PATCHes, not duplicates), find-miss → nil, remove, and fail-fast on missing creds.
- [ ] **Step 5** gem suite green. **Commit.**

---

### Task 2: engine wiring — `Rbrun.dns` + wildcard ensure

**Files:** `lib/rbrun.rb`, `lib/rbrun/config.rb`, `app/services/rbrun/preview_domain.rb`,
`lib/rbrun/engine.rb`; test `test/services/rbrun/preview_domain_test.rb`

- [ ] **Step 1** `Rbrun.dns(provider = nil, tenant: nil, **opts)` beside `Rbrun.sandbox` — `require
  "rbrun/dns"`, `build(Rbrun::Dns, config(tenant).dns_provider, provider:, **opts)`.
- [ ] **Step 2** config accessors: `preview_domain`, `preview_target`, `preview_max_sockets` (default 5).
- [ ] **Step 3** `Rbrun::PreviewDomain` — `.host_for(token)` → `"#{token}-preview.#{preview_domain}"`;
  `.ensure!` upserts `*.<preview_domain>` → `preview_target` (CNAME, proxied). No-ops without config.
- [ ] **Step 4** call `PreviewDomain.ensure!` from `after_initialize`, guarded + warn-only (never fail boot).
- [ ] **Step 5** tests: host_for shape; ensure! no-ops unconfigured; ensure! upserts once when configured
  (inject a stub DNS double — the *engine* seam, not a fake HTTP client). **Commit.**

---

### Task 2.5: `Rbrun::ServiceExposure` — per-[worktree,name] intent + token (CORRECTION)

Supersedes the token-on-RepoService choice: a preview host must resolve to ONE sandbox's service.

**Files:** migration (add `rbrun_service_exposures`; drop `preview_token`/`previewed`/`shared_public`
from `rbrun_repo_services`), `app/models/rbrun/service_exposure.rb`, `worktree.rb` (has_many),
`repo_service.rb` (remove the flags + token), `service_launcher.rb` (flags move here);
tests updated.

- [ ] `Rbrun::ServiceExposure` — `belongs_to :worktree`, Tenanted inherited, `name`, `preview_token`
  (unique, `SecureRandom.urlsafe_base64(6)` minted on first preview), `previewed`, `shared_public`.
  Unique `[worktree_id, name]`. `#live_run = worktree.service_runs.find_by(name:, status: "running")`.
- [ ] `Worktree has_many :service_exposures, dependent: :destroy`.
- [ ] `ServiceLauncher` reads/writes the flags here (per worktree), keyed by `[@worktree, name]`; the
  `previewed`/`shared_public`/`preview_token` on `RepoService` are removed.
- [ ] Tests: token minted once + stable across a `repo_services_start` reset; resolution lands in the
  right worktree; two worktrees of one repo get **distinct** tokens. **Commit.**

### Task 3: the proxy — HTTP

**Files:** `lib/rbrun/preview_proxy.rb` (Rack middleware), `lib/rbrun/engine.rb` (insert); resolution via
`Rbrun::ServiceExposure.find_by(preview_token:)`; test `test/integration/rbrun/preview_proxy_test.rb`

- [ ] **Step 1** share addressing: a stable per-service `preview_token` on `RepoService` (single label,
  `SecureRandom.urlsafe_base64(8)`), minted on first preview. Migration + model.
- [ ] **Step 2** middleware: match `Host` against `*-preview.<preview_domain>` → resolve token → service
  + live `ServiceRun`. Unknown ⇒ 404. Not running ⇒ 503.
- [ ] **Step 3** level gate: `shared_public?` ⇒ open; else require rbrun session (reuse the engine's
  session lookup) ⇒ 302 to login when absent.
- [ ] **Step 4** relay via Faraday `:async_http`, attaching `x-daytona-preview-token`; strip hop-by-hop
  both directions; pass status/headers/body through.
- [ ] **Step 5** tests (WebMock upstream): unknown host 404; not-running 503; previewed-not-shared
  anonymous ⇒ redirect to login; previewed-not-shared with session ⇒ 200; shared ⇒ anonymous 200; token
  never appears in body/headers; asset path relays. **Commit.**

---

### Task 4: the proxy — WebSockets (capped)

**Files:** `lib/rbrun/preview_proxy.rb` (+`lib/rbrun/preview_socket.rb`); test
`test/integration/rbrun/preview_socket_test.rb`

- [ ] **Step 1** detect `Upgrade: websocket`; enforce the cap **before** hijacking — at/over
  `preview_max_sockets` ⇒ 503, never degrade the app. Counter is process-global and decremented in
  `ensure`.
- [ ] **Step 2** hijack; open TLS upstream; forward the handshake **with the token header**; relay `101`.
- [ ] **Step 3** pump bytes both directions — **never parse frames**. Close the peer on half-close;
  release the counter and both sockets in `ensure`.
- [ ] **Step 4** test with a real loopback upstream (a tiny TCPServer speaking the handshake, in-test —
  not a fake object): bytes round-trip; cap refuses the (N+1)th upgrade with 503; counter returns to zero
  after close. **Commit.**

---

### Task 5: rewire levels 2 + 3 onto our edge

**Files:** `app/services/rbrun/service_launcher.rb`, `app/tools/rbrun/tools/{preview_service,share_public}.rb`,
`gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb`, `app/views/rbrun/services/_panel.html.erb`,
`CLAUDE.md`, both specs; tests updated

- [ ] **Step 1** `preview` mints `preview_token` if absent and sets `previewed`; the service's public URL
  becomes `PreviewDomain.host_for(token)` — **not** the provider URL. `ServiceRun#url` keeps the
  *provider* URL (the proxy's upstream); a new `#preview_host` is what humans get.
- [ ] **Step 2** `share_public` no longer calls `set_public` — it only sets `shared_public`. **Remove the
  `set_public` call sites**; leave the adapter capability in the gem (harmless, and honest about what the
  provider offers) but assert in a test that the engine never calls it.
- [ ] **Step 3** panel + tools return the rbrun host.
- [ ] **Step 4** **rewrite invariant #10** to match: engine owns the edge, per-service enforcement is real,
  provider box-wide switch is never used. Update both specs' stale sections.
- [ ] **Step 5** full suite + rubocop. **Commit.**

---

### Task 6: the bypass seam

**Files:** `lib/rbrun.rb`, `app/services/rbrun/service_launcher.rb`; test
`test/services/rbrun/preview_edge_seam_test.rb`

- [ ] **Step 1** `Rbrun.preview_edge` accessor (set-once host DI, defaults nil).
- [ ] **Step 2** launcher: when set, `preview`/`share_public` call `expose(run)` and store its URL;
  `stop_preview`/`stop_sharing` call `revoke(run)`. When set, `PreviewDomain.ensure!` no-ops and the
  middleware declines (host app owns the path).
- [ ] **Step 3** tests: with a seam object set, no DNS call is made, the stored URL is the host's, and
  revoke fires on both withdrawals. **Commit.**

---

### Task 7: `bin/setup` — dev tunnel

**Files:** `bin/setup`, `README.md` (a short "dev exposure" note)

- [ ] **Step 1** idempotent: list tunnel by name → create if absent → `PUT` ingress
  (`hostname → http://localhost:PORT`, fallback `http_status:404`) → upsert CNAME → `GET …/token`.
- [ ] **Step 2** print `TUNNEL_TOKEN=…` and the hostname; store nothing.
- [ ] **Step 3** run it for real against `rb.run`; confirm re-running changes nothing (idempotent) and
  prints the same token. **Commit.**

---

### Task 8: dogfood

**Files:** `lib/tasks/rbrun/dogfood/preview_daytona.rake`

- [ ] **Step 1** replace phase 2/3 assertions with the edge: previewed ⇒ rbrun host, anonymous ⇒ login;
  shared ⇒ anonymous 200 **with an asset**; `db`/`jobs`/`css` hosts ⇒ 404; provider URL still ⇒ provider
  login (box never public); revoke ⇒ back to login; `stop_preview` ⇒ 404.
- [ ] **Step 2** run it. Print the rbrun preview host for human validation. **Commit.**

## Self-Review

- Enforcement is real now (no route ⇒ unreachable), so the dogfood asserts 404 on unshared hosts rather
  than merely "no flag set".
- One wildcard record ⇒ no per-share DNS lifetime, no leak on missed revocation.
- `rack.hijack` verified identical on Puma + Falcon ⇒ one implementation, cap is config not code.
- The seam is checked in both directions: set ⇒ no DNS/no proxy; unset ⇒ engine owns it.
- Invariant #10 is rewritten in the same commit that changes the behaviour (Task 5), never left lying.
