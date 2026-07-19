# Phase 6 — Engine host: Worktrees (GitHub-backed) + auth — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the **Worktree** (1 sandbox + 1 git branch, `has_many :sessions`), relocate the sandbox from `Session` to `Worktree`, record the commits the agent pushes each turn, and add optional built-in auth — so the deliverable is git history on GitHub, not DB blobs.

**Architecture:** A `Worktree` owns a git branch (spun off a base ref in a repo) and the sandbox that branch is checked out in; `Session belongs_to :worktree` and runs its turns in `worktree.sandbox`. The agent edits files and `git commit`+`push`es via its own Bash/git tools during a turn; after the turn, `Session#run_turn` reads the new commit SHAs from git and records `Commit` rows. Tenancy roots on the Worktree. Optional auth: config-seeded, extensible `User` rows + a `current_tenant` hook.

**Tech Stack:** Rails engine, ActiveReord, `bcrypt` (has_secure_password), Minitest. Depends on Phases 3–5. `Rbrun.config.github_pat` provides the agent's GitHub access.

## Global Constraints

- **Worktree = 1 sandbox + 1 branch**, `has_many :sessions`. The sandbox lives on the **Worktree**, not the Session (`Session#sandbox` delegates to `worktree.sandbox`).
- **The agent commits via git tools** (Bash) — nothing auto-commits. rbrun **reads the resulting SHAs** after the turn and records `Commit` rows. Reading is **guarded**: a non-git sandbox (unit tests) records nothing, never errors.
- **Tenancy roots on the Worktree**; a Session inherits its tenant slug from its Worktree on create.
- **GitHub is the store.** Work is git history on GitHub, not blobs in the DB. Provisioning + the agent's pushes use `Rbrun.config.github_pat`.
- **Naming:** `Worktree` is rbrun's term, NOT a git worktree.
- **Dogfood:** `lib/tasks/rbrun/dogfood/worktree.rake`, one scenario, never variabilized; a real turn where the agent edits + commits + pushes. Creds/repo from `.env` (`GITHUB_PAT`, `RBRUN_WORKTREE_REPO`).
- **Ruby 3.4.4.**

---

## File Structure

**Created:**
- `app/models/rbrun/worktree.rb`, `app/models/rbrun/commit.rb`
- `app/models/rbrun/user.rb`
- `db/migrate/<ts>_create_rbrun_worktrees.rb`, `<ts+1>_create_rbrun_commits.rb`, `<ts+2>_add_worktree_to_rbrun_sessions.rb`, `<ts+3>_create_rbrun_users.rb`
- `config/initializers/rbrun_users.rb` (config-seeded users)
- `lib/tasks/rbrun/dogfood/worktree.rake`
- Tests: `test/models/rbrun/worktree_test.rb`, `test/models/rbrun/user_test.rb`, `test/support/rbrun_factories.rb`

**Modified:**
- `rbrun.gemspec` — depend on `bcrypt`.
- `lib/rbrun.rb` — `current_tenant` hook.
- `app/models/rbrun/session.rb` — `belongs_to :worktree`, `#sandbox` delegates, tenant inheritance, `run_turn` records commits.
- `test/dummy/config/initializers/rbrun.rb` — leave as-is (users already seeded there).
- All Session-creating tests → create via the new factory helper.

---

### Task 1: `Worktree` + `Commit` models + provisioning

**Files:**
- Create: `app/models/rbrun/worktree.rb`, `app/models/rbrun/commit.rb`, migrations, `test/models/rbrun/worktree_test.rb`
- Test: `test/models/rbrun/worktree_test.rb`

**Interfaces:**
- Produces: `Rbrun::Worktree` (`Tenanted`; `repo`/`base`/`branch`; `has_many :sessions`/`:commits`; `#sandbox`; `#head_sha`; `#provision_command`; `#provision!`); `Rbrun::Commit` (`belongs_to :worktree`, `:session` optional; `sha`/`message`).

- [ ] **Step 1: migrations**

`db/migrate/20260719130000_create_rbrun_worktrees.rb`:

```ruby
class CreateRbrunWorktrees < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_worktrees do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :repo,   null: false   # "owner/name"
      t.string :base,   null: false, default: "main"
      t.string :branch, null: false
      t.timestamps
    end
    add_index :rbrun_worktrees, Rbrun.config.tenancy_key
  end
end
```

`db/migrate/20260719130001_create_rbrun_commits.rb`:

```ruby
class CreateRbrunCommits < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_commits do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.references :session,  null: true,  foreign_key: { to_table: :rbrun_sessions }
      t.string :sha, null: false
      t.text   :message
      t.timestamps
    end
    add_index :rbrun_commits, %i[worktree_id sha], unique: true
  end
end
```

- [ ] **Step 2: write the failing test**

`test/models/rbrun/worktree_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class WorktreeTest < ActiveSupport::TestCase
    test "creating a worktree assigns a branch and is tenanted" do
      wt = Worktree.create!(tenant: "acme", repo: "acme/webapp", base: "main")
      assert_match(/\Arbrun\/wt-[0-9a-f]+\z/, wt.branch)
      assert_includes Worktree.for_tenant("acme"), wt
    end

    test "#sandbox is labelled by the worktree and shared" do
      wt = Worktree.create!(tenant: "acme", repo: "a/b")
      assert_instance_of Rbrun::Sandbox::Local, wt.sandbox
      assert_same wt.sandbox, wt.sandbox
    ensure
      wt&.sandbox&.destroy!
    end

    test "provision_command clones the repo with the PAT and spins the branch off base" do
      Rbrun.config.github_pat = "ghp_TOKEN"
      wt = Worktree.create!(tenant: "acme", repo: "acme/webapp", base: "develop")
      cmd = wt.provision_command
      assert_includes cmd, "x-access-token:ghp_TOKEN@github.com/acme/webapp.git"
      assert_includes cmd, "checkout -B #{wt.branch}"
      assert_includes cmd, "develop"
    end

    test "head_sha returns nil for a non-git sandbox (guarded)" do
      wt = Worktree.create!(tenant: "acme", repo: "a/b")
      assert_nil wt.head_sha
    ensure
      wt&.sandbox&.destroy!
    end

    test "commits belong to the worktree and are unique per sha" do
      wt = Worktree.create!(tenant: "acme", repo: "a/b")
      wt.commits.create!(sha: "abc", message: "one")
      assert_raises(ActiveRecord::RecordNotUnique) { wt.commits.create!(sha: "abc", message: "dup") }
    end
  end
end
```

- [ ] **Step 3: run — verify it fails**

Run: `bin/rails test test/models/rbrun/worktree_test.rb` → FAIL (models missing). (Migrate the dummy first — see Step 5.)

- [ ] **Step 4: the models**

`app/models/rbrun/worktree.rb`:

```ruby
require "securerandom"

module Rbrun
  # rbrun's unit of work (NOT a git worktree): one git branch + one sandbox, shared by all the
  # Sessions under it. The branch is spun off `base` in `repo`; the agent commits + pushes to it via
  # its git tools during turns.
  class Worktree < ApplicationRecord
    include Rbrun::Tenanted

    has_many :sessions, class_name: "Rbrun::Session", dependent: :destroy
    has_many :commits,  class_name: "Rbrun::Commit",  dependent: :destroy

    before_validation :assign_branch, on: :create

    # The branch's checkout, shared by every Session under this Worktree. Addressed by the worktree id.
    def sandbox = @sandbox ||= Rbrun.sandbox(labels: { worktree: id.to_s })

    # Clone the repo into the sandbox and spin the branch off base — using the config github_pat. Run
    # once, when the worktree is first used.
    def provision!
      sandbox.exec!(provision_command, timeout: 300)
      self
    end

    def provision_command
      pat = Rbrun.config.github_pat
      url = "https://x-access-token:#{pat}@github.com/#{repo}.git"
      ws  = sandbox.workspace
      <<~SH.strip
        cd #{ws} && \
        (git rev-parse --git-dir >/dev/null 2>&1 || (git clone #{url} . && git remote set-url origin #{url})) && \
        git fetch origin #{base} && git checkout #{base} && git checkout -B #{branch} && \
        git push -u origin #{branch}
      SH
    end

    # The branch HEAD in the sandbox, or nil for a non-git sandbox (unit tests) — guarded, never raises.
    def head_sha
      r = sandbox.exec("cd #{sandbox.workspace} && git rev-parse HEAD 2>/dev/null")
      r.success? ? r.stdout.strip : nil
    end

    private

    def assign_branch = self.branch ||= "rbrun/wt-#{SecureRandom.hex(4)}"
  end
end
```

`app/models/rbrun/commit.rb`:

```ruby
module Rbrun
  # A commit the agent pushed during a turn — rbrun records the SHA (GitHub is the store).
  class Commit < ApplicationRecord
    belongs_to :worktree, class_name: "Rbrun::Worktree"
    belongs_to :session,  class_name: "Rbrun::Session", optional: true
  end
end
```

- [ ] **Step 5: migrate + run — verify pass**

Run:
```bash
bin/rails app:db:migrate && RAILS_ENV=test bin/rails app:db:migrate
bin/rails test test/models/rbrun/worktree_test.rb
```
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 6: commit**

```bash
git add app/models/rbrun/worktree.rb app/models/rbrun/commit.rb db/migrate test/models/rbrun/worktree_test.rb test/dummy/db
git commit -m "feat(engine): Worktree (1 sandbox + 1 branch) + Commit models + provisioning"
```

---

### Task 2: relocate the sandbox — `Session belongs_to :worktree`

**Files:**
- Modify: `app/models/rbrun/session.rb`, migration
- Create: `test/support/rbrun_factories.rb`
- Modify: every Session-creating test + the `session_log` dogfood

**Interfaces:**
- Produces: `Session belongs_to :worktree` (required); `Session#sandbox` → `worktree.sandbox`; `Session#tenant` inherited from the worktree on create. Factory helper `rbrun_worktree(tenant:)` / `rbrun_session(tenant:)`.

- [ ] **Step 1: migration — add worktree to sessions**

`db/migrate/20260719130002_add_worktree_to_rbrun_sessions.rb`:

```ruby
class AddWorktreeToRbrunSessions < ActiveRecord::Migration[8.1]
  def change
    add_reference :rbrun_sessions, :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
  end
end
```

(If a dev DB has stray sessions, clear them first: `bin/rails runner 'Rbrun::Session.delete_all'`.)

- [ ] **Step 2: a test factory (Session now needs a Worktree)**

`test/support/rbrun_factories.rb`:

```ruby
module RbrunFactories
  def rbrun_worktree(tenant: "acme", repo: "acme/webapp", base: "main")
    Rbrun::Worktree.create!(tenant: tenant, repo: repo, base: base)
  end

  def rbrun_session(tenant: "acme", worktree: nil)
    Rbrun::Session.create!(worktree: worktree || rbrun_worktree(tenant: tenant))
  end
end

class ActiveSupport::TestCase
  include RbrunFactories
end
```

Require it from `test_helper.rb` (after `rails/test_help`): `require_relative "support/rbrun_factories"`.

- [ ] **Step 3: relocate the sandbox + inherit tenant on Session**

In `app/models/rbrun/session.rb`, replace the `belongs_to`/sandbox area:

```ruby
  class Session < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create

    has_many :messages, -> { order(:created_at, :id) },
             class_name: "Rbrun::SessionMessage", dependent: :destroy
    has_many :commits, class_name: "Rbrun::Commit", dependent: :nullify

    enum :status,
         { idle: "idle", working: "working", needs_approval: "needs_approval", done: "done", failed: "failed" },
         default: "idle"

    # The Worktree's sandbox — one branch checkout shared by all Sessions under it.
    def sandbox = worktree.sandbox
```

and add the private method (near the bottom, before `end`):

```ruby
    private

    def inherit_tenant = self.tenant ||= worktree&.tenant
```

- [ ] **Step 4: update every Session-creating test to use the factory**

Replace `Session.create!(tenant: "acme")` → `rbrun_session(tenant: "acme")` (or build a worktree explicitly) in:
`test/rbrun/tenanted_test.rb`, `test/rbrun/constructors_test.rb`, `test/tools/rbrun/application_tool_test.rb`, `test/tools/rbrun/identity_test.rb`, `test/models/rbrun/session_test.rb`, `test/models/rbrun/session_message_test.rb`, `test/services/rbrun/agent_turn_test.rb`, `test/models/rbrun/session_run_turn_test.rb`.

For `session_test.rb`'s "#sandbox resolves a local box" test, the sandbox now comes from the worktree — assert `rbrun_session.sandbox` is `Rbrun::Sandbox::Local` (unchanged assertion, new source).

Update `lib/tasks/rbrun/dogfood/session_log.rake`: create a worktree first, then `Rbrun::Session.create!(worktree: wt)`, and destroy `wt.sandbox`/`wt` at the end.

- [ ] **Step 5: migrate + run the whole engine suite**

Run:
```bash
bin/rails runner 'Rbrun::Session.delete_all' 2>/dev/null
bin/rails app:db:migrate && RAILS_ENV=test bin/rails app:db:migrate
bin/rails test
```
Expected: whole engine suite green (all Session tests now go through a Worktree).

- [ ] **Step 6: commit**

```bash
git add app/models/rbrun/session.rb db/migrate test/support test/test_helper.rb test/ lib/tasks/rbrun/dogfood/session_log.rake test/dummy/db
git commit -m "feat(engine): relocate sandbox to Worktree — Session belongs_to :worktree"
```

---

### Task 3: record the commits the agent pushed each turn

**Files:**
- Modify: `app/models/rbrun/session.rb`
- Test: `test/models/rbrun/commit_recording_test.rb`

**Interfaces:**
- Produces: `Session#run_turn` records `Commit` rows for commits made during the turn (HEAD before → HEAD after via `git log`), guarded so a non-git sandbox records nothing.

- [ ] **Step 1: write the failing test (a fake sandbox that scripts git output)**

`test/models/rbrun/commit_recording_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class CommitRecordingTest < ActiveSupport::TestCase
    # A worktree whose sandbox reports two new commits between the before/after HEADs.
    class GitWorktree < Worktree
      self.table_name = "rbrun_worktrees"
      def head_sha = @heads.shift
      def sandbox = @fake ||= FakeSandbox.new
      def stub_heads(*shas) = @heads = shas
    end

    class FakeSandbox
      def workspace = "/ws"
      def exec(cmd, **)
        if cmd.include?("git log")
          Rbrun::Sandbox::ExecResult.new(exit_code: 0, stdout: "sha2\tsecond\nsha1\tfirst\n", stderr: "")
        else
          Rbrun::Sandbox::ExecResult.new(exit_code: 0, stdout: "", stderr: "")
        end
      end
    end

    class NoopRuntime
      def run(**) = { type: "result", stop_reason: "end_turn" }
    end

    test "run_turn records the commits made during the turn" do
      wt = GitWorktree.create!(tenant: "acme", repo: "a/b")
      wt.stub_heads("HEAD_BEFORE", "HEAD_AFTER") # head_sha called before, then after the turn
      session = Session.create!(worktree: wt)
      session.run_turn("edit and commit", runtime: NoopRuntime.new)
      assert_equal %w[sha2 sha1].sort, wt.reload.commits.pluck(:sha).sort
      assert_equal session, wt.commits.first.session
    end

    test "a non-git sandbox records nothing and does not error" do
      session = rbrun_session
      session.run_turn("no git here", runtime: NoopRuntime.new)
      assert_equal 0, session.commits.count
      assert session.done?
    end
  end
end
```

- [ ] **Step 2: run — verify it fails**

Run: `bin/rails test test/models/rbrun/commit_recording_test.rb` → FAIL (no commit recording).

- [ ] **Step 3: record commits in run_turn**

In `app/models/rbrun/session.rb`, update `run_turn` and add `record_commits!`:

```ruby
    def run_turn(content, runtime: nil)
      working!
      before = worktree.head_sha
      turn = Rbrun::AgentTurn.new(session: self, runtime: runtime)
      turn.run(content)
      record_commits!(before)
      turn.gated? ? needs_approval! : done!
      turn
    rescue StandardError => e
      failed!
      messages.create!(role: "assistant", event_type: "error", payload: { "message" => e.message })
      raise
    end
```

and, in the private section:

```ruby
    # Read the commits the agent pushed during the turn (HEAD before → after) and record them.
    # Guarded: a non-git sandbox (unit tests, un-provisioned worktrees) records nothing.
    def record_commits!(before)
      after = worktree.head_sha
      return if after.nil? || after == before

      range = before ? "#{before}..#{after}" : after
      out = worktree.sandbox.exec("cd #{worktree.sandbox.workspace} && git log --format='%H%x09%s' #{range} 2>/dev/null")
      return unless out.success?

      out.stdout.each_line do |line|
        sha, message = line.strip.split("\t", 2)
        next if sha.to_s.empty?

        worktree.commits.find_or_create_by!(sha: sha) { |c| c.session = self; c.message = message }
      end
    end
```

- [ ] **Step 4: run — verify pass; full suite green**

Run: `bin/rails test test/models/rbrun/commit_recording_test.rb && bin/rails test`
Expected: PASS.

- [ ] **Step 5: commit**

```bash
git add app/models/rbrun/session.rb test/models/rbrun/commit_recording_test.rb
git commit -m "feat(engine): run_turn records the commits the agent pushed (guarded)"
```

---

### Task 4: optional built-in auth — `User` + config seeding + `current_tenant`

**Files:**
- Modify: `rbrun.gemspec`, `lib/rbrun.rb`
- Create: `app/models/rbrun/user.rb`, migration, `config/initializers/rbrun_users.rb`, `test/models/rbrun/user_test.rb`

**Interfaces:**
- Produces: `Rbrun::User` (`Tenanted`, `has_secure_password`, unique `email`); config `c.user`s upserted on boot (idempotent, extensible row); `Rbrun.current_tenant` (host-set resolver → slug; falls back to the default `"rbrun"`).

- [ ] **Step 1: bcrypt + migration**

In `rbrun.gemspec`: `spec.add_dependency "bcrypt"`. Run `bundle install`.

`db/migrate/20260719130003_create_rbrun_users.rb`:

```ruby
class CreateRbrunUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_users do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :rbrun_users, :email, unique: true
  end
end
```

- [ ] **Step 2: the model + current_tenant hook**

`app/models/rbrun/user.rb`:

```ruby
module Rbrun
  # Optional built-in auth identity. Config-seeded (c.user), but the ROW is canonical and extensible —
  # add columns (roles, settings) without touching the config contract.
  class User < ApplicationRecord
    include Rbrun::Tenanted
    has_secure_password
    validates :email, presence: true, uniqueness: true
  end
end
```

In `lib/rbrun.rb`, add to `class << self`:

```ruby
    # Host-set resolver → the acting tenant slug (used when built-in auth is off). Defaults to the
    # single-tenant slug.
    attr_writer :current_tenant_resolver

    def current_tenant = (@current_tenant_resolver&.call) || Rbrun::Config::DEFAULT_TENANT
```

`config/initializers/rbrun_users.rb`:

```ruby
# Idempotently upsert config-declared users into rbrun's own users table. The config is the
# declarative source for the auth-critical fields; the DB row is canonical and extensible.
Rails.application.config.to_prepare do
  next unless Rbrun::User.table_exists?

  Rbrun.config.users.each do |u|
    user = Rbrun::User.find_or_initialize_by(email: u[:email])
    user.password = u[:password]
    user.public_send("#{Rbrun.config.tenancy_key}=", u[:tenant])
    user.save!
  end
end
```

- [ ] **Step 3: write + run the test**

`test/models/rbrun/user_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class UserTest < ActiveSupport::TestCase
    test "config-seeded dev user exists with tenant and a working password" do
      user = User.find_by(email: "dev@rbrun.test")
      assert user, "dummy initializer seeds dev@rbrun.test"
      assert_equal "rbrun", user.tenant
      assert user.authenticate("password")
      refute user.authenticate("wrong")
    end

    test "email is unique" do
      User.create!(email: "u@x.com", password: "pw", tenant: "acme")
      assert_raises(ActiveRecord::RecordInvalid) { User.create!(email: "u@x.com", password: "pw", tenant: "acme") }
    end

    test "current_tenant falls back to the default slug when no resolver is set" do
      Rbrun.current_tenant_resolver = nil
      assert_equal "rbrun", Rbrun.current_tenant
    end
  end
end
```

Run:
```bash
bin/rails app:db:migrate && RAILS_ENV=test bin/rails app:db:migrate
bin/rails test test/models/rbrun/user_test.rb
```
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 4: commit**

```bash
git add rbrun.gemspec lib/rbrun.rb app/models/rbrun/user.rb config/initializers/rbrun_users.rb db/migrate test/models/rbrun/user_test.rb Gemfile.lock test/dummy/db
git commit -m "feat(engine): optional built-in auth — User + config seeding + current_tenant hook"
```

---

### Task 5: Dogfood — a real Worktree turn that commits to GitHub

**Files:**
- Create: `lib/tasks/rbrun/dogfood/worktree.rake`

**Interfaces:**
- Consumes: `Rbrun::Worktree`, `Rbrun::Session`, `Rbrun::Dogfood`. Reads `GITHUB_PAT` + `RBRUN_WORKTREE_REPO` (+ Daytona/Anthropic) from `.env`.

Creates a Worktree (spins a branch + provisions the sandbox), runs a real turn in a Session under it where the agent edits a file and `git commit`+`push`es via its tools, and confirms the commit landed and was recorded.

- [ ] **Step 1: write the dogfood**

`lib/tasks/rbrun/dogfood/worktree.rake`:

```ruby
# frozen_string_literal: true

require_relative "support"

# Phase 6 dogfood — a real Worktree turn (real Daytona box + real GitHub). Creates a Worktree (branch
# off base), provisions the sandbox, runs a turn where the agent writes a file and commits+pushes via
# git, and confirms the commit landed on the branch and was recorded. Creds/repo from .env
# (GITHUB_PAT, RBRUN_WORKTREE_REPO, DAYTONA_*, ANTHROPIC_OAUTH_TOKEN).
#
#   bin/rails app:dogfood:worktree

namespace :dogfood do
  desc "Phase 6: a real turn in a Worktree edits a file and pushes a commit to GitHub"
  task worktree: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    repo = ENV["RBRUN_WORKTREE_REPO"].to_s
    if ENV["GITHUB_PAT"].to_s.empty? || repo.empty? || ENV["DAYTONA_API_KEY"].to_s.empty? || ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty?
      abort "Missing .env (GITHUB_PAT, RBRUN_WORKTREE_REPO, DAYTONA_API_KEY, ANTHROPIC_OAUTH_TOKEN)."
    end

    Rbrun.configure do |c|
      c.github_pat       = ENV["GITHUB_PAT"]
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 20 } }
    end

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo: repo, base: "main")
    begin
      dog.header "provisioning"
      wt.provision!
      dog.ok "the branch was spun + checked out", wt.head_sha.present?
      base_sha = wt.head_sha

      session = wt.sessions.create!
      session.run_turn(
        "Create a file NOTES_#{Time.now.to_i}.md with a one-line note, then commit it with git " \
        "(git add, git commit -m 'rbrun dogfood note') and push it to the current branch."
      )

      dog.header "the turn"
      dog.ok "status landed on done", session.reload.done?

      dog.header "the commit"
      dog.ok "HEAD advanced past the base", wt.head_sha.present? && wt.head_sha != base_sha
      dog.ok "rbrun recorded at least one commit", session.commits.any?
      dog.info "commit", session.commits.last&.slice(:sha, :message)&.values&.join(" — ")
      remote = wt.sandbox.exec("cd #{wt.sandbox.workspace} && git ls-remote origin #{wt.branch}").stdout.to_s
      dog.ok "the branch exists on GitHub (git ls-remote)", remote.include?(wt.branch)
    ensure
      wt.sandbox.destroy!
      wt.destroy!
    end
  end
end
```

- [ ] **Step 2: run the dogfood** (needs `GITHUB_PAT` + `RBRUN_WORKTREE_REPO` in `.env`)

Run: `bin/rails app:dogfood:worktree`
Expected (with creds): provisioning ✓, a real turn where the agent writes + commits + pushes, HEAD advances, the commit is recorded, and the branch exists on GitHub. Missing creds → clean abort.

- [ ] **Step 3: full verification + commit**

```bash
bin/rails test            # engine green
bin/rubocop               # 0 offenses
(cd gems/rbrun-sandbox && bundle exec rake test)   # 28/0
(cd gems/rbrun-runtime && bundle exec rake test)   # green
git add lib/tasks/rbrun/dogfood/worktree.rake
git commit -m "feat(dogfood): worktree — a real turn commits to GitHub (Phase 6 gate)"
```

---

## Self-Review

**1. Spec coverage (Phase 6 contract):**
- `Worktree` (repo/base/branch, `#sandbox`, `Tenanted`, `has_many :sessions`) + provisioning → Task 1. ✓
- Relocate sandbox from Session to Worktree (`Session belongs_to :worktree`, `#sandbox` delegate, tenant inheritance) → Task 2. ✓
- Record per-turn commit SHAs (agent commits via git; rbrun reads) → Task 3, guarded. ✓
- Optional built-in auth (`User` + config-seeded, extensible; `current_tenant` hook) → Task 4. ✓
- Dogfood `worktree` (real turn edits + commits + pushes) → Task 5. ✓
- Work is git history on GitHub, not DB blobs. ✓

**2. Placeholder scan:** No TODO/"handle later". `<ts>` = "use a real timestamp". Every code block complete.

**3. Type/name consistency:** `Worktree` (`repo`/`base`/`branch`, `#sandbox`, `#head_sha`, `#provision_command`/`#provision!`, `has_many :sessions`/`:commits`); `Commit` (`worktree`/`session`, `sha`/`message`); `Session belongs_to :worktree`, `#sandbox` → `worktree.sandbox`, `run_turn` records commits; `Rbrun::User` (`Tenanted`, `has_secure_password`); `Rbrun.current_tenant`. The factory `rbrun_session` threads a Worktree so every existing Session test keeps working.

**Risk areas (validated by dogfood):** real `git clone`/`checkout -B`/`push` provisioning + the agent committing via its git tools + the PAT credential helper actually authenticating — only the `worktree` dogfood exercises these; the offline tests prove the model, the command-building, and the guarded commit-recording.

**Note carried to Phase 7:** the UI renders a Worktree's branch + its `Commit` rows (the "diff view"), and `SessionMessage#decide_approval!`/`run_frozen_call!` resumes a gated turn — both build on the models here.
