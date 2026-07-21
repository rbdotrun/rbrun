# rbrun-server + deploy tools + preview-deploy skill — Design

**Status:** design of record. Supersedes the local `bin/dev`/`bin/ssh`/`bin/destroy` remote-dev scripts
(removed) — provisioning + deployment move _into the engine_ as the `:server` provider family and agent
tools, exactly as the top-level design anticipated (`§9 Future — rbrun-servers`; `c.server_provider`;
`FAMILIES = […, :server]` is already live in `lib/rbrun/config.rb`).

## 1. Purpose

Let the agent take a worktree from "code in a sandbox" to "a running, publicly reachable deployment" without
any laptop-side bash. Four capabilities, as tools:

1. **provision** a server (Hetzner),
2. **point DNS** at the new server's IP (reuse the `:dns` family),
3. **prepare** the deploy setup (Dockerfile + Kamal config) in the worktree,
4. **deploy** with Kamal (local builder).

The deployment is owned by the **worktree**: `1 worktree = 1 sandbox (Daytona, dev) = 1 deploy_target
(Hetzner server + its DNS host)`. The sandbox and the deploy server are _distinct infra_, each 1:1 with the
worktree — mirroring how `Worktree#sandbox` and per-`[worktree, name]` `ServiceExposure` already work.

```
Worktree ──has_one──▶ sandbox        (Daytona, dev env for the agent)
         ──has_one──▶ deploy_target ──▶ Hetzner server + DNS host   (the deployed app)
```

## 2. The gem — `gems/rbrun-server/`

Family `:server`, module `Rbrun::Server`. Mirrors `rbrun-dns ↔ Rbrun::Dns`. Pure gem: **depends on no other
rbrun gem** (invariant #1). External deps only:

- `faraday` + `async-http` for the Hetzner Cloud API (invariant #5 — Faraday on the async-http adapter; the
  same reason we do **not** shell out to the `hcloud` CLI, which also sidesteps its v1.51 SIGSEGV/capacity
  crashes).
- `kamal` for the deploy step (local builder).

Adapter resolution is **constant lookup in the family namespace** — no registry, no self-registration
(invariant #1), identical to `Rbrun::Dns`:

```ruby
module Rbrun
  module Server
    class Error < StandardError; end
    ADAPTERS = { kamal_hetzner: "KamalHetzner" }.freeze

    def self.new(provider:, config: {}, **opts)
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown server provider #{provider.inspect} (known: #{ADAPTERS.keys.join(', ')})"
      end
      const_get(const_name).new(config: config, **opts)
    end
  end
end
```

### 2.1 `Rbrun::Server::Base` — the interface every adapter MUST respect

Same pattern just retrofitted into `rbrun-dns` (`Rbrun::Dns::Base`): a base class whose every method
`raise NotImplementedError`, so a provider that forgets one fails loud, not with a confusing `NoMethodError`.
Pure documentation + enforcement; no behaviour, no state. All mutating methods MUST be idempotent by resource
identity (name), so callers can re-run freely (invariant #11).

```ruby
module Rbrun
  module Server
    class Base
      # Create the server if absent, or return the existing one (find-or-create by name). Blocks until it
      # has a public IP / reaches `running`. @return [Rbrun::Server::Node]
      def create_server(name:, type:, region:, image:, ssh_keys: [], user_data: nil, labels: {})
        raise NotImplementedError, "#{self.class}#create_server"
      end

      # The server with this name, or nil. @return [Node, nil]
      def find_server(name:) = raise NotImplementedError, "#{self.class}#find_server"

      # Every server the account owns, optionally narrowed by label. @return [Array<Node>]
      def list_servers(label: nil) = raise NotImplementedError, "#{self.class}#list_servers"

      # Destroy the server (by name). True if one was deleted, false if there was nothing to delete.
      # @return [Boolean]
      def destroy_server(name:) = raise NotImplementedError, "#{self.class}#destroy_server"

      # Deploy the app onto the target's server via Kamal (local builder). Runs `kamal deploy` in
      # `work_dir` with the resolved server IP + registry creds. @return [Rbrun::Server::DeployResult]
      def deploy(work_dir:, host:, server_ip:, env: {})
        raise NotImplementedError, "#{self.class}#deploy"
      end
    end
  end
end
```

Value objects (mirroring `Rbrun::Dns::Record`, plain `Data`/`Struct`, framework-free):

- `Rbrun::Server::Node` — `id, name, ip, status, region`.
- `Rbrun::Server::DeployResult` — `ok (bool), output (string)`.

### 0. Division of labor (the contract — do not blur it)

- **The agent drives the tool calls and PREPARES THE REPO.** Guided by the `rails-kamal-deployment` skill,
  the agent inspects the repo and — **if missing** — adds a `Dockerfile` and a `config/deploy.yml` that
  targets our infra via the `KAMAL_*` env below, fixes a stale `Gemfile.lock`, adds a DB accessory + secrets,
  then **commits + pushes**. All repo-prep is the agent's, NOT the engine's.
- **The engine does the infra + enforces.** Provision the box, DNS, expose the `KAMAL_*` env, clone the
  **pushed** branch, run kamal, record state. `deploy` **blocks unless the branch is committed + pushed**.
  The deployed version is the commit sha (no separate tag tool). The engine NEVER writes `deploy.yml`/
  `Dockerfile` — no config injection, no repo-prep in Ruby.

### 2.2 `Rbrun::Server::KamalHetzner` — the adapter

- **Config, validated fail-fast at init** (invariant #2): `{ hcloud_token:, registry: { server:, username:,
  password: } }`. A blank `hcloud_token` raises `Error`. **SSH keys are NOT config** — they flow per call
  (the engine generates + stores a keypair per deployment; see §4).
- **Provisioning** talks to the Hetzner Cloud API over Faraday/async-http:
  - `create_server(name:, type:, region:, image:, ssh_public_key:, …)` → `GET /servers?name=` (find), else
    `POST /servers` (uploading `ssh_public_key` under the server's own name, rolling over `fsn1→nbg1→hel1`
    on a 412 placement/capacity error); poll until `running` + has an IP; return a `Node`. Idempotent.
  - `find_server` / `list_servers` / `destroy_server` → the obvious `GET`/`DELETE` (delete swallows 404).
- **Deploy** — `deploy(work_dir:, host:, server_ip:, ssh_private_key:, env:)` shells `kamal deploy` in
  `work_dir` (local builder), materializing `ssh_private_key` to a 0600 temp file and exposing the **infra
  env the repo's `deploy.yml` reads**: `KAMAL_SERVER_IP`, `KAMAL_HOST`, `KAMAL_REGISTRY_SERVER/USERNAME/
  PASSWORD`, `KAMAL_SSH_KEY_FILE`, plus the app secrets passed in `env` (from `RepoSecret`). `app_logs`
  runs `kamal app logs` the same way.

## 3. Engine composition root

One line in `lib/rbrun.rb`, identical shape to `Rbrun.dns` / `Rbrun.sandbox` (invariant #2 — only the engine
reads `Rbrun.configure`, via `Rbrun.build`):

```ruby
def server(provider = nil, tenant: nil, **opts)
  build(Rbrun::Server, config(tenant).server_provider, provider: provider, **opts)
end
```

Config (already accepted by the metaprogrammed `server_provider=`):

```ruby
c.server_provider = {
  default:       :kamal_hetzner,
  kamal_hetzner: { hcloud_token: ENV["HCLOUD_TOKEN"],
                   registry: { server: "docker.io", username: ENV["REGISTRY_USER"],
                               password: ENV["REGISTRY_PASSWORD"] } },
}
```

## 4. DB — `Rbrun::DeployTarget` (1:1 with `Worktree`)

Tenant-scoped, own DB (invariant #8), exactly like `ServiceExposure`:

```ruby
class DeployTarget < ApplicationRecord
  include Rbrun::Tenanted
  belongs_to :worktree, class_name: "Rbrun::Worktree"
  before_validation :inherit_tenant, on: :create
  # columns: provider, server_type, region, image, host, server_id, server_ip, status,
  #          ssh_public_key, ssh_private_key,     # the per-deployment keypair WE generate + store
  #          deploy_tag, deployed_sha, last_deploy_log
  private
  def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
end
```

- `Worktree has_one :deploy_target`.
- **Unique index on `worktree_id`** — one target per worktree; the worktree _is_ the key, so no name to get
  wrong. Find-or-create is `worktree.deploy_target || worktree.create_deploy_target!(…)`.
- `host` defaults to a worktree-derived label under `c.preview_domain` (overridable); `server_ip`/`server_id`
  fill in after provision; `status` tracks `pending → provisioned → deploying → deployed → failed → torn_down`.
- **The per-deployment SSH keypair is ours** — `Rbrun::DeployKeys.ensure!(target)` generates it (via the
  `sshkey` gem) and stores it here; the public half is uploaded to the provider, the private half deploys.
- `deployed_sha` / `deploy_tag` = the deployed commit (the tag IS the sha); `last_deploy_log` = the build+
  deploy output (surfaced by `deploy_status` / `deploy_logs`).
- Migration under the engine's `db/migrate` (own-DB connection via `connects_to`, invariant #8).

## 5. Tools (`Rbrun::Tools::*`, agentic, idempotent)

Every tool acts on **the current session's worktree's** target (`session.worktree`), find-or-create — no name
argument. `< Rbrun::ApplicationTool`, one operation each, runs back in Ruby. **The engine does not write any
repo files** — the agent prepares the repo (§0) and commits + pushes it before `deploy`. **Six tools** (no
`prepare_deploy`, no `save_deploy_tag`):

| Tool                | Does                                                                                                      | Notes                                                                                    |
| ------------------- | --------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `provision_server`  | `DeployKeys.ensure!` → `Rbrun.server.create_server(…, ssh_public_key:)`; write `server_id`/`server_ip`.   | idempotent by server name (= worktree-derived, label `rbrun-worktree=<id>`)              |
| `create_deploy_dns` | `Rbrun.dns.upsert(name: host, type: "A", content: server_ip)`.                                            | the `:dns` family does the work                                                          |
| `deploy`            | **block unless the branch is committed + pushed** → enqueue `DeployJob` → `DeployRunner` (clone pushed branch → `Rbrun.server.deploy`). | **`needs_approval!`**; runs off-turn; version = commit sha |
| `deploy_status`     | Show the target: live URL (`https://host`), status, deployed sha, server ip.                              | read-only                                                                                |
| `deploy_logs`       | `DeployRunner#logs` → `Rbrun.server.app_logs` (`kamal app logs`), else stored `last_deploy_log`.          | parity with `repo_services` logs                                                         |
| `teardown_deploy`   | `Rbrun.server.destroy_server` **+** `Rbrun.dns.remove(host)`; reset the target row.                       | invariant #11 — leaves nothing behind                                                    |

`Rbrun::DeployRunner` clones the **pushed** branch and runs kamal with the infra env — it injects **no**
config and does **no** repo-prep. `DeployRunner.branch_pushed?(worktree)` is the enforcement predicate the
`deploy` tool gates on.

## 6. Skill — `app/skills/rails-kamal-deployment/`

A DB-seeded skill (`SkillSeeder` from `app/skills/<slug>/`) — the agent's playbook. It teaches the agent to
**kamal-ize a Rails repo**: inspect it, add a `Dockerfile` and `config/deploy.yml` (reading the `KAMAL_*`
infra env) **if missing**, fix a stale `Gemfile.lock`, add a Postgres/MySQL accessory + `.kamal/secrets`,
**commit + push**, then call `provision_server → create_deploy_dns → deploy`, poll `deploy_status`, and
`teardown_deploy` when done. Carries `deploy.yml` / `.kamal/secrets` / Postgres / MySQL templates inline.

```
app/skills/preview-deploy/
  SKILL.md                     # when-to-use + the ordered lifecycle + gotchas
  examples/Dockerfile.rails    # curated per-stack examples the agent adapts
  examples/Dockerfile.node
  examples/deploy.yml          # Kamal template (local builder, registry, server placeholder)
```

The templates live in the **skill** (human-curated), not the pure gem (decision: "skill provides templates");
`prepare_deploy` renders them into the worktree.

## 7. Invariants respected

- **#1 no registry** — adapter by constant lookup in `Rbrun::Server`; the gem depends on no other rbrun gem.
- **#2 engine is the only composition root** — pure gem takes an explicit config hash; only `Rbrun.server`
  (engine) reads `Rbrun.configure`; the adapter validates its own config fail-fast.
- **#5 Faraday on async-http** — Hetzner API client; no CLI, no vendor SDK.
- **#8 own DB + tenancy** — `DeployTarget` is Tenanted, `inherit_tenant` from the worktree, own-DB migration.
- **#9 RubyLLM engine-only** — tools are `ApplicationTool`; the gem never sees RubyLLM.
- **#10 exposure is a human decision** — `deploy` (which makes the app publicly reachable) is `needs_approval!`.
- **#11 idempotency** — find-or-create server (by name), upsert DNS, upsert setup files, `teardown_deploy`
  destroys server + DNS and resets the row. Nothing is ever left behind.

## 8. Testing

- **Gem** (`gems/rbrun-server/test/`): drive the real adapter against a **stubbed wire** (WebMock) for the
  Hetzner API — never a hand fake — exactly like `rbrun-dns`. Assert `KamalHetzner < Base` and that `Base`
  methods raise `NotImplementedError` until overridden. `deploy` is unit-tested by stubbing the `kamal`
  invocation (assert argv + env), not by running a real deploy.
- **Engine** (`test/`): model tests for `DeployTarget` (1:1 uniqueness, tenant inheritance); tool tests
  driving each tool with a fake `Rbrun.server`/`Rbrun.dns` seam; boot test that `deploy` is gated.
- **Dogfood** (`lib/tasks/rbrun/dogfood/`): a single scenario driving **one real** provision → dns → deploy →
  teardown against real Hetzner + Cloudflare, reaping the server + DNS in `ensure` (invariant #11, invariant
  #6 — never variabilized).

## 9. Out of scope (explicit)

- Free-floating **named** deploy targets ("prod-eu") reusable across worktrees — the target is worktree-bound
  by decision. If cross-worktree reuse is ever needed it is a later, additive change (the row already carries
  everything but the `belongs_to`).
- Non-Hetzner server providers and non-Kamal deploy — new adapters implementing `Rbrun::Server::Base`, no
  engine change (the whole point of the family seam).
- Webhooks — a **sandbox** capability (Daytona), stays with `bin/setup` + the `:sandbox` family; not `:server`.
