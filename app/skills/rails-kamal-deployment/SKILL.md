---
name: rails-kamal-deployment
description: Deploy a Rails app to a live URL with Kamal on rbrun-managed infra. Use when the user asks to deploy, publish, or ship a preview of a Rails repo. Teaches you to prepare the repo (add Kamal setup if missing), commit + push, then drive the deploy tools.
---

# Deploying a Rails app with Kamal

You take a Rails repo from "code in the worktree" to a **live HTTPS URL**. rbrun owns the infra
(server, DNS, registry, SSH key, TLS); YOU own preparing the repo so Kamal can build + boot it.

## The infra rbrun gives you (do NOT hardcode these)

The engine sets these in Kamal's environment **AT DEPLOY TIME**. You will NOT see them in your shell while
preparing the repo — that is expected and correct. **Trust the contract:** write `<%= ENV["KAMAL_HOST"] %>`
etc. in `config/deploy.yml` and NEVER hardcode an IP or host (you don't have the box yet when writing it,
and hardcoding breaks re-deploys).

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
   - Add a DB accessory if the app needs one; remove any repo-specific `.kamal/hooks` that assume other infra.
   - **CRITICAL — sync `Gemfile.lock`.** Rails Dockerfiles run `bundle install` FROZEN, which fails if the
     lock is even slightly out of sync with the `Gemfile` (a changed version constraint, an added/removed
     gem). A stale lock is the #1 cause of a failed image build — never skip this. Fix it:
     - If bundler + the app's Ruby are available, run `bundle lock` and commit `Gemfile.lock`.
     - **If Ruby ISN'T in the sandbox (common), hand-edit `Gemfile.lock`.** Its `DEPENDENCIES` section (near
       the bottom) must list each gem with the SAME constraint as the `Gemfile`. E.g. if `Gemfile` has
       `gem "colorize", "~> 1.1"` but `Gemfile.lock` shows a bare `colorize` under `DEPENDENCIES`, change it
       to `colorize (~> 1.1)`. Match every mismatched gem, then commit.

3. **Declare secrets + ask for any missing env.** Read what the app actually needs — every `ENV[...]` it
   reads (`RAILS_MASTER_KEY`, `POSTGRES_PASSWORD`, a `DATABASE_URL`, third-party API keys, …), and read
   `config/database.yml` specifically to learn the EXACT DB env names the `production:` block interpolates
   (they differ per app — see the Postgres section). Cross-check against what's already stored with
   `list_deploy_secrets` (it returns the NAMES on file, never values), so you can see what's present vs.
   missing. Make sure each name the app needs is stored and matches, and **ask the user for anything that's
   missing** (use `request_secrets`) rather than guessing or leaving it blank. Never commit secret VALUES —
   only the `.kamal/secrets` references.

4. **Commit + push everything you added/changed** — including a newly-created `config/deploy.yml` and
   `Dockerfile`. This is mandatory: `deploy` clones the pushed branch and REFUSES if the branch isn't
   pushed. The deployed version is the commit sha (no separate tag).

5. **`deploy_config`** (get the exact image, registry, AND the required `ssh:` block — user `deploy`) →
   **`provision_server`** → **`create_deploy_dns`** → **`deploy`** (needs your approval).

6. **The deploy runs off-turn — watch it and iterate.** After `deploy`, poll **`deploy_status`** until it
   reports `deployed` or `failed` (don't assume success). If it's `failed`, call **`deploy_logs`** and read
   the REAL build/deploy output — do NOT guess at the cause. The usual culprit is a stale `Gemfile.lock`
   (fix per step 2), a wrong `app_port`, or a missing secret. Fix the ACTUAL error, commit + push, and
   `deploy` again. Repeat until `deployed`, then hand the user the URL from `deploy_status`. Use
   **`deploy_exec`** to run commands on the box (`docker ps`, container logs, `df -h`) when you need the
   server's real state. **`teardown_deploy`** when done.

## config/deploy.yml (target our infra via env)

# FIRST call the `deploy_config` tool — it returns the exact `service`, `image`, `registry_server`, and
# `registry_username`. Put those LITERAL values in deploy.yml. Do NOT guess the registry namespace and do
# NOT use a bare image name like `dummy-rails` — the registry rejects it ("push access denied /
# unauthorized"). `servers` is the IP, `proxy.host` is the hostname — do NOT swap them.
```yaml
service: <service>                  # <- the `service` from deploy_config
image: <registry_username>/<service>   # <- the `image` from deploy_config — a real value, NEVER bare
servers:
  web:
    - <%= ENV["KAMAL_SERVER_IP"] %>                    # the IP, not the host
proxy:
  ssl: true                      # Let's Encrypt, auto
  host: <%= ENV["KAMAL_HOST"] %>
  app_port: 80                   # Thruster/puma; match your Dockerfile's EXPOSE
registry:
  server: <registry_server>        # <- registry_server from deploy_config (literal, e.g. docker.io)
  username: <registry_username>    # <- registry_username from deploy_config (literal)
  password:
    - KAMAL_REGISTRY_PASSWORD      # the password IS a secret — reference it, injected at deploy time
ssh:                               # REQUIRED — from deploy_config. The box runs a non-root `deploy` user;
  user: deploy                     #   root login + password auth are DISABLED. Omit this and kamal tries
  keys: [ <%= ENV["KAMAL_SSH_KEY_FILE"] %> ]   #   root -> password prompt -> deploy fails.
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

**First, read `config/database.yml` and match the env EXACTLY.** The `production:` block tells you the
precise names the app interpolates — and they vary. A Rails-8 default reads a single `DATABASE_URL`; an
older app reads discrete `POSTGRES_HOST`/`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`; a bespoke app
reads app-specific names (`MYAPP_DB_PASSWORD`, `PGHOST`, …). Whatever the file reads, `deploy.yml` MUST
supply **those same names** (clear for hosts/users, `secret:` for passwords) — otherwise the container
starts but can't connect (`could not translate host name` / `password authentication failed`) and the
deploy fails health-check. If the app reads `DATABASE_URL`, set it in `env.clear` pointing at the
accessory host, e.g. `DATABASE_URL: postgres://app@myapp-db/app_production` with `POSTGRES_PASSWORD` as the
secret and `password: <%= ENV["POSTGRES_PASSWORD"] %>` spliced in — or reference a full URL secret. Use
`deploy_exec` to `cat config/database.yml` on the box if unsure, and confirm every name lines up before
you deploy.

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
