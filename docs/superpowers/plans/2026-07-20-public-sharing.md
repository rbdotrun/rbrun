# Public Sharing Implementation Plan (exposure ladder, level 3)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** make exactly one running service reachable by anyone with a link, without ever opening the
sandbox.

**Architecture:** `Rbrun::PublicShare` (worktree + service name + opaque token) + one unauthenticated
route `/p/:token(/*path)` that reverse-proxies to that one `ServiceRun`, attaching the provider preview
token server-side. Scoping is enforced by routing: an unshared service has no route.

## Global Constraints

- CLAUDE.md invariant #10 (the ladder). **Never** call a provider's box-wide public switch.
- `public` strictly requires `previewed`: `share_public` errors otherwise, and `stop_preview` revokes.
- The provider preview token never reaches the browser.
- `share_public` is `needs_approval!`; `stop_sharing` ungated.
- Tests + `bin/rubocop` green after each task. Work on `main`.

---

### Task 1: `Rbrun::PublicShare` model + migration

**Files:** `db/migrate/20260720190000_create_rbrun_public_shares.rb`, `app/models/rbrun/public_share.rb`,
`app/models/rbrun/worktree.rb` (MODIFY), `test/models/rbrun/public_share_test.rb`

- [ ] **Step 1: migration**

```ruby
class CreateRbrunPublicShares < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_public_shares do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string Rbrun.config.tenancy_key, null: false
      t.string :name,  null: false
      t.string :token, null: false
      t.timestamps
    end
    add_index :rbrun_public_shares, :token, unique: true
    add_index :rbrun_public_shares, [ :worktree_id, :name ], unique: true
  end
end
```

- [ ] **Step 2: model**

```ruby
module Rbrun
  # A revocable credential making ONE running service reachable by anyone with the link. Keyed on
  # [worktree, name] — NOT on RepoService (repo-wide, not bound to a box) and NOT on ServiceRun (destroyed
  # by every repo_services_start reset), so the link survives restarts and dies only when revoked.
  class PublicShare < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create
    before_validation :assign_token,   on: :create

    validates :name, :token, presence: true

    def service_run = worktree.service_runs.find_by(name: name)

    private

    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
    def assign_token   = self.token ||= SecureRandom.urlsafe_base64(32)
  end
end
```

- [ ] **Step 3:** `Worktree`: `has_many :public_shares, class_name: "Rbrun::PublicShare", dependent: :destroy`

- [ ] **Step 4: test** — token auto-generated + unique; unique per `[worktree, name]`; tenant inherited;
  `service_run` resolves the live run; destroying the worktree destroys shares.

- [ ] **Step 5:** `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/rbrun/public_share_test.rb` → PASS. **Commit.**

---

### Task 2: launcher share/unshare + the preview cascade

**Files:** `app/services/rbrun/service_launcher.rb` (MODIFY), `test/services/rbrun/service_launcher_test.rb`

**Produces:** `#share_public(name)` → share | `:unknown` | `:not_previewed` | `:not_running`;
`#stop_sharing(name)` → `true`; `#stop_preview` cascades.

- [ ] **Step 1: implement**

```ruby
    # Level 3. STRICTLY requires level 2 — a service that is not previewed can never be public.
    def share_public(name)
      run = find(name)
      return :unknown unless run || saved(name)
      return :not_running unless run&.status_running?
      return :not_previewed unless run.url.present? && saved(name)&.previewed?

      @worktree.public_shares.find_or_create_by!(name: name)
    end

    def stop_sharing(name)
      @worktree.public_shares.where(name: name).destroy_all
      true
    end
```

- [ ] **Step 2: the cascade** — in `stop_preview`, before returning, add `stop_sharing(name)` so
  withdrawing preview revokes any share. (public ⇒ previewed, enforced on both edges.)

- [ ] **Step 3: tests**
  - `share_public` on a non-previewed service ⇒ `:not_previewed`, **no share created**
  - preview → `share_public` ⇒ share with a token
  - `stop_sharing` ⇒ destroyed
  - **`stop_preview` revokes the share** (the cascade)
  - a second `share_public` is idempotent (same share)

- [ ] **Step 4:** run tests → PASS. **Commit.**

---

### Task 3: the public edge (unauthenticated reverse proxy)

**Files:** `app/controllers/rbrun/public_previews_controller.rb`, `config/routes.rb` (MODIFY),
`lib/rbrun/engine.rb` (MODIFY: filter_parameters `:token`),
`test/controllers/rbrun/public_preview_test.rb`

- [ ] **Step 1: route** (before the authenticated resources)

```ruby
  # THE ONLY UNAUTHENTICATED ROUTE: the public edge. Proxies to exactly one shared ServiceRun.
  match "p/:token(/*path)", to: "public_previews#show", via: :all, as: :public_preview
```

- [ ] **Step 2: controller**

```ruby
require "faraday"

module Rbrun
  # The public edge. The ONLY unauthenticated endpoint: it reverse-proxies to exactly ONE shared
  # ServiceRun, attaching the provider preview token SERVER-SIDE (it must never reach the browser).
  # Scoping is enforced by routing — an unshared service has no route and cannot surface, whatever it
  # binds to. The sandbox itself is never made provider-public.
  class PublicPreviewsController < Rbrun::ApplicationController
    skip_before_action :require_authentication, raise: false
    skip_forgery_protection

    HOP_BY_HOP = %w[connection keep-alive transfer-encoding upgrade proxy-authenticate
                    proxy-authorization te trailer].freeze

    def show
      share = Rbrun::PublicShare.find_by(token: params[:token])
      return head(:not_found) unless share # unknown or revoked — indistinguishable

      run = share.service_run
      return head(:service_unavailable) unless run&.status_running? && run.url.present?

      relay(upstream(run, params[:path]), run)
    end

    private

    def upstream(run, path) = [ run.url.chomp("/"), path.presence ].compact.join("/")

    def relay(url, run)
      response = connection.run_request(request.request_method.downcase.to_sym, url, body_for, headers_for(run))
      response.headers.each { |k, v| self.response.headers[k] = v unless HOP_BY_HOP.include?(k.downcase) }
      render body: response.body, status: response.status,
             content_type: response.headers["content-type"].presence || "text/html"
    end

    def body_for = request.raw_post.presence

    # The provider preview token is attached HERE, server-side, and never rendered to the client.
    def headers_for(run)
      h = { "x-daytona-preview-token" => run.token.to_s }
      h["content-type"] = request.content_type if request.content_type.present?
      h
    end

    def connection
      @connection ||= Faraday.new(params: request.query_parameters) do |f|
        f.adapter :async_http
      end
    end
  end
end
```

- [ ] **Step 3:** engine `filter_parameters += [ :token ]`.

- [ ] **Step 4: tests** (stub the upstream with WebMock — real client, stubbed wire):
  - unknown token ⇒ 404
  - share whose service is not running ⇒ 503
  - valid share ⇒ upstream body relayed, and the request carried `x-daytona-preview-token`
  - the token never appears in the rendered body/headers
  - a service with **no** share has no route to it (only the shared name resolves)

- [ ] **Step 5:** PASS. **Commit.**

---

### Task 4: tools + gate card

**Files:** `app/tools/rbrun/tools/share_public.rb`, `app/tools/rbrun/tools/stop_sharing.rb`,
`app/components/rbrun/sessions/tools_validation/share_public/component.{rb,html.erb}`,
`lib/rbrun/engine.rb` (MODIFY), `app/services/rbrun/service_conventions.rb` (MODIFY),
`test/tools/rbrun/public_sharing_tools_test.rb`

- [ ] **Step 1:** `SharePublic` — `needs_approval!`, param `name`. Maps launcher symbols to `error(...)`;
  success returns `{ "data" => { "name", "url" => public_preview_url, "public" => true } }`.
- [ ] **Step 2:** `StopSharing` — ungated, param `name`.
- [ ] **Step 3:** gate card stating plainly: *anyone with the link, no account required*.
- [ ] **Step 4:** register both in `engine.rb`; extend `ServiceConventions::PROMPT` with the ladder
      (run → preview → public; public needs the user's approval; never share a db/queue/worker).
- [ ] **Step 5:** tests — `share_public` needs_approval in the manifest; not-previewed ⇒ error;
      previewed ⇒ url; `stop_sharing` ⇒ revoked.
- [ ] **Step 6:** full suite + rubocop → PASS. **Commit.**

---

### Task 5: panel UI

**Files:** `app/views/rbrun/services/_panel.html.erb` (MODIFY),
`app/controllers/rbrun/services_controller.rb` (MODIFY), `config/routes.rb` (MODIFY),
`test/controllers/rbrun/services_panel_test.rb`

- [ ] **Step 1:** routes `post :share_public`, `post :stop_sharing` on the services member block.
- [ ] **Step 2:** controller actions delegating to the launcher.
- [ ] **Step 3:** panel — `[Share publicly]` renders **only when previewed**; when shared, show a globe
      badge + the public URL (copyable) + `[Stop sharing]`. Public state must be visually loud.
- [ ] **Step 4:** tests — button hidden when not previewed; shown when previewed; shared row exposes the
      public URL; stop_sharing revokes.
- [ ] **Step 5:** `bun run build` if any JS; full suite + rubocop. **Commit.**

---

### Task 6: dogfood phase 3

**Files:** `lib/tasks/rbrun/dogfood/preview_daytona.rake` (MODIFY)

- [ ] **Step 1:** after phase 2, a third turn: "make the web service publicly shareable" → the agent calls
      `share_public` → gate → harness approves.
- [ ] **Step 2:** assertions, on the real box with postgres + jobs + rails running:
  - a `PublicShare` exists for `web` only; **none** for `db`/`jobs`
  - **anonymous, no cookies** GET of `/p/<token>` ⇒ **200** and the Rails app's HTML
  - the raw Daytona preview URL, fetched anonymously, **still terminates at the provider login**
    (the box was never opened)
  - `stop_sharing("web")` ⇒ the public URL now **404s**
  - `stop_preview("web")` ⇒ the share is revoked (cascade)
- [ ] **Step 3:** print the public URL for human validation. Run it. **Commit.**

NOTE: the edge runs on the rbrun host, so the dogfood exercises it in-process via an integration request
rather than over the public internet; the anonymity assertion is "no session cookie, no provider account".

## Self-Review

- Ladder enforced on both edges: `share_public` refuses when not previewed; `stop_preview` revokes.
- Scoping by routing, not by bind address — asserted in the dogfood via db/jobs having no share.
- Provider box-wide flag never called anywhere (grep-able absence).
- Token: 32-byte urlsafe, unique, filtered from logs, rotated on re-share.
- 404 (not 403) for unknown/revoked tokens — no enumeration signal.
