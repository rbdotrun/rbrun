---
name: rails-kamal-deployment
description: Deploy a Rails app to a live URL with Kamal on rbrun-managed infra. Use when the user asks to deploy, publish, or ship a preview of a Rails repo. Teaches you to prepare the repo (add Kamal setup if missing), commit + push, then drive the deploy tools.
---

# Deploying a Rails app with Kamal

You take a Rails repo from "code in the worktree" to a **live HTTPS URL**. rbrun owns the infra
(server, DNS, registry, SSH key, TLS); YOU own preparing the repo so Kamal can build + boot it.

## The infra rbrun gives you (do NOT hardcode these)

At deploy time the engine sets these in Kamal's environment. Your `config/deploy.yml` must READ them,
never bake in values:

- `KAMAL_SERVER_IP`     — the provisioned box's IP (use for `servers`)
- `KAMAL_HOST`          — the public host, e.g. `myapp.rb.run` (use for `proxy.host`)
- `KAMAL_REGISTRY_SERVER` / `KAMAL_REGISTRY_USERNAME` / `KAMAL_REGISTRY_PASSWORD` — the container registry
- `KAMAL_SSH_KEY_FILE`  — path to the SSH key Kamal uses to reach the box
- App secrets you declared (e.g. `RAILS_MASTER_KEY`, `POSTGRES_PASSWORD`) — injected from stored repo secrets

## Steps (in order)

1. **Inspect the repo.** Is there a `Dockerfile` and a `config/deploy.yml`? What's the DB (Postgres/MySQL/SQLite)?
   Is `Gemfile.lock` in sync with `Gemfile`? A modern Rails 8 app usually already has a Dockerfile.

2. **Add the Kamal setup if missing.** Create the files the repo lacks:
   - **`Dockerfile`** — if absent, add one for the app's stack (see templates). A modern Rails 8 app usually
     already ships one; if so, leave it.
   - **`config/deploy.yml`** — if absent, add it, reading the infra env above (never hardcode IPs/hosts).
   - **`.kamal/secrets`** — map secret names to `$ENV`.
   - Add a DB accessory if the app needs one; fix a stale `Gemfile.lock` (bundle install); remove any
     repo-specific `.kamal/hooks` that assume other infra.

3. **Declare secrets.** For each secret the app needs (`RAILS_MASTER_KEY`, `POSTGRES_PASSWORD`, …), make
   sure it's stored (ask the user / request_secrets). Never commit secret VALUES — only the `.kamal/secrets`
   references.

4. **Commit + push everything you added/changed** — including a newly-created `config/deploy.yml` and
   `Dockerfile`. This is mandatory: `deploy` clones the pushed branch and REFUSES if the branch isn't
   pushed. The deployed version is the commit sha (no separate tag).

5. **`provision_server`** → **`create_deploy_dns`** → **`deploy`** (needs your approval). Poll
   **`deploy_status`** until it reports `deployed`, then hand the user the URL. Use **`deploy_logs`** to
   debug. **`teardown_deploy`** when done.

## config/deploy.yml (target our infra via env)

```yaml
service: myapp
image: <%= ENV["KAMAL_REGISTRY_USERNAME"] %>/myapp
servers:
  web:
    - <%= ENV["KAMAL_SERVER_IP"] %>
proxy:
  ssl: true                      # Let's Encrypt, auto
  host: <%= ENV["KAMAL_HOST"] %>
  app_port: 80                   # Thruster/puma; match your Dockerfile's EXPOSE
registry:
  server: <%= ENV["KAMAL_REGISTRY_SERVER"] %>
  username: [ KAMAL_REGISTRY_USERNAME ]
  password: [ KAMAL_REGISTRY_PASSWORD ]
ssh:
  user: root
  keys: [ <%= ENV["KAMAL_SSH_KEY_FILE"] %> ]
env:
  clear:
    RAILS_ENV: production
  secret:
    - RAILS_MASTER_KEY
builder:
  arch: amd64
```

## .kamal/secrets

```
KAMAL_REGISTRY_USERNAME=$KAMAL_REGISTRY_USERNAME
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
RAILS_MASTER_KEY=$RAILS_MASTER_KEY
```

## Postgres (add when the app needs it)

Add to `config/deploy.yml`:

```yaml
env:
  clear:
    POSTGRES_HOST: myapp-db          # kamal names the accessory container <service>-db on a shared network
    POSTGRES_USER: app
    POSTGRES_DB: app_production
  secret:
    - RAILS_MASTER_KEY
    - POSTGRES_PASSWORD
accessories:
  db:
    image: postgres:16
    host: <%= ENV["KAMAL_SERVER_IP"] %>
    env:
      clear:
        POSTGRES_USER: app
        POSTGRES_DB: app_production
      secret:
        - POSTGRES_PASSWORD
    directories:
      - data:/var/lib/postgresql/data
```

Add `POSTGRES_PASSWORD=$POSTGRES_PASSWORD` to `.kamal/secrets`, and store a `POSTGRES_PASSWORD` secret.

## MySQL (alternative)

Same shape, `image: mysql:8`, `MYSQL_*` env (`MYSQL_ROOT_PASSWORD` secret, `MYSQL_DATABASE`), app
`DATABASE_URL`/`MYSQL_HOST: myapp-db`.

## Rules

- The deploy config targets rbrun infra via the `KAMAL_*` env — never hardcode IPs/hosts/registry.
- Commit + push before deploying (enforced). The deployed version is the sha.
- Reap with `teardown_deploy` when finished — don't leave infra running.
