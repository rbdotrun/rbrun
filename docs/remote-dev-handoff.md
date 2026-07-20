# Remote dev host — hand-off for the next agent

You are (or will be) a Claude Code session running **on a public Hetzner box** that serves the rbrun dummy
app. This is where real preview work happens, because the box is genuinely internet-reachable. Read this
before touching anything.

## 0. The box is EPHEMERAL — always discover, never hardcode

We spin up (`bin/dev`) and tear down (`bin/destroy`) this box constantly. **The IP changes every time.**
Nothing may hardcode it.

- **Discover the IP:** `HCLOUD_TOKEN="$HETZNER_API_TOKEN" hcloud server ip rbrun-dev`
- From the laptop just use `bin/ssh` (it resolves the IP itself) — `bin/ssh`, `bin/ssh claude`, `bin/ssh <cmd>`.
- DNS follows automatically: `bin/dev` upserts `dev.rb.run` A → the current IP, and preview hosts point at
  `dev.rb.run` (the app origin), so they never need the raw IP.
- Hetzner recycles IPs, so a fresh box may reuse an old one with a stale host key. Always SSH with
  `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` (bin/ssh already does).

## 1. Lifecycle (run from the laptop)

- `bin/dev` — full idempotent pass: find-or-create box → `dev.rb.run` A → box → install mise+Ruby 3.4.4,
  Caddy, cloudflared, Claude Code → clone/`reset --hard origin/main` the repo (via `gh auth token`) → scp
  `.env` → bundle + `app:db:prepare` → app+Caddy+tunnel as services → validate Claude → open a session.
  **It `git reset --hard origin/main` on the box** — commit + push box-local work before re-running.
- `bin/ssh` / `bin/ssh claude` / `bin/ssh <cmd>` — access.
- `bin/destroy` — delete the box + `dev.rb.run`. Nothing else (ssh keys, preview records untouched). Idempotent.

## 2. How the app is served (do not re-muddle)

- **Caddy on the box terminates TLS on demand and reverse-proxies to the app on `:3000`.** So `dev.rb.run`
  and every `<token>-preview.rb.run` serve HTTPS with **NO tunnel in the app path.** `/etc/caddy/Caddyfile`:
  `on_demand_tls { ask http://127.0.0.1:3000/up }` + `https:// { tls { on_demand } reverse_proxy 127.0.0.1:3000 }`.
  On-demand means the first hit to a new host provisions its Let's Encrypt cert (first request is slow).
- **`preview_target` is the app's own origin (`dev.rb.run`), never a tunnel.**
- The **cloudflared tunnel is webhooks-only** and irrelevant to the app/previews.
- Services (systemd, on the box): `rbrun-app` (puma :3000, `RAILS_ENV=development`, EnvironmentFile
  `/root/rbrun/.env`), `caddy`, `cloudflared`.

## 3. App config on the box (previews are ARMED)

Driven by `.env` + `test/dummy/config/initializers/rbrun.rb`: `sandbox=daytona`, `dns=cloudflare`,
`preview_domain=rb.run`, `preview_target=dev.rb.run`. So the full preview chain is wired and should work:

```
<token>-preview.rb.run  --CNAME-->  dev.rb.run --A--> box  -->  Caddy (on-demand TLS)  -->  app :3000
     -->  Rbrun::PreviewProxy (matches Host, resolves token in DB)  -->  private Daytona sandbox
          (provider token attached SERVER-SIDE; the sandbox is never made public)
```

## 4. THE MISSION: prove a clickable PUBLIC preview link

This is built but never proven end-to-end live. Do it on the box (a Claude session, or `bin/rails runner`):

1. Create a worktree with a Daytona sandbox, start a service in it (see `Rbrun::ServiceLauncher#start` /
   the `repo_services_start` tool). Confirm the run is `running`.
2. `launcher.preview(name)` then `launcher.share_public(name)` — mints the `ServiceExposure` token, creates
   `<token>-preview.rb.run` CNAME → `dev.rb.run`, resolves the sandbox provider URL onto the run as upstream.
3. `curl https://<token>-preview.rb.run` (find the host via `exposure.preview_host`) → expect **200**, the
   sandbox app relayed **anonymously**, the token never in the body, and the raw Daytona URL still demanding
   provider auth (box stays private). First hit may lag while Caddy issues the cert.
4. `launcher.stop_preview(name)` → DNS record deleted → the host 404s.

Reap Daytona boxes at the end (invariant #11) — never leave a sandbox behind.

## 5. Code map (previews)

- `lib/rbrun/preview_proxy.rb` — Rack middleware at the TOP of the stack; Host → token → live run → relay,
  provider token attached server-side, hop-by-hop stripped; WebSockets via `rack.hijack` (capped).
- `app/models/rbrun/service_exposure.rb` — per-`[worktree, name]` intent + stable `preview_token`.
- `app/services/rbrun/preview_domain.rb` — `expose!`/`unexpose!` (one CNAME per shared preview → `preview_target`).
- `app/services/rbrun/service_launcher.rb` — `preview` / `share_public` / `stop_preview` / `stop_sharing`.
- `app/services/rbrun/preview_sentinel.rb` (+ job) — reconciles the DNS edge to the DB (source of truth).
- `gems/rbrun-dns/` — Cloudflare adapter (`upsert` / `remove` / `list`).
- Design: `docs/superpowers/specs/2026-07-20-preview-edge-design.md` + the plan beside it.

## 6. Operating the box

- Restart app after code changes: `systemctl restart rbrun-app`.
- Logs: `journalctl -u rbrun-app -f` · `journalctl -u caddy -f`.
- Ruby is via mise: prefix commands with `mise exec --` (or use a login shell, where mise is active).
- **Engine rake tasks are namespaced under `app:`** (e.g. `bin/rails app:db:prepare`, `app:dogfood:*`).
- Re-sync from the laptop with `bin/dev` — but it hard-resets to `origin/main`, so push box work first.
- Claude Code is authed (`CLAUDE_CODE_OAUTH_TOKEN` in `/etc/profile.d`), onboarding pre-seeded, git identity
  + push credential configured — you can commit + push from the box directly.

## 7. Hard-won gotchas

- Tunnel ≠ app. The tunnel never serves the app or previews; `preview_target` is the app origin.
- Rails **development** host-authorization blocks unknown hosts — `.rb.run` is allowed via
  `RBRUN_PREVIEW_DOMAIN` (see `test/dummy/config/environments/development.rb`). New host patterns need adding.
- mise compiles Ruby from source; the box has the build deps (`libssl-dev`, etc.) so it links system OpenSSL.
- Idempotency is mandatory (invariant #11): find-or-create / upsert / reap. A leaked Daytona box or DNS
  record is a bug.

## 8. Open / flagged

- **Level-2 (private, session-gated) previews return 403** — `PreviewProxy` sits above the session
  middleware, so it can't read the rbrun session; needs a cross-subdomain SSO handshake. **PUBLIC previews
  are the current target.**
- cloudflared webhook tunnel may not be settled on the box — only matters when wiring Daytona webhooks;
  ignore for preview work.
- Caddy's on-demand `ask` points at `/up`, which 200s for any host — fine for a dev box, tighten later.
