# Repo selection in the composer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Move repo selection from the global sidebar switcher (`current_repo` cookie) into the composer as a per-chat badge, and clean out the entire `current_repo` plumbing behind it — so a repo is an input to a *run*, not a global mode.

**Architecture:** A repo is picked in the composer (a `RepoBadge`), which writes hidden `repo`/`base` fields into the compose form. The existing switcher dialog is reused, its row-selection **retargeted** from `POST /repos/switch` to a **client-side pick** (a `window` CustomEvent the badge consumes). Composing from root **creates a new `Worktree`** (repo → resolved worktree; bare when none) + a `Session` + the first turn. The index becomes **worktrees grouped by repo**; opening a worktree shows its sessions. Once a chat has a turn, its repo is **locked** (derived from `session.messages.none?`). `Worktree → repo` is unchanged; **no schema change**.

**Tech Stack:** Rails 8.1 engine, ViewComponent primitives via `component(...)`/`custom(...)`, Stimulus (bun-built), Capybara/Cuprite system tests.

## Global Constraints

- Reach every component via `component("<name>", …)` / `custom("folder/name", …)` — never `render(...Component.new)` in a view, never a raw control.
- **No schema change.** `Session → Worktree → repo` stays. "Locked" is derived (`session.messages.none?`), not a column.
- **Clean refactor — no ghosts.** By the end, these must not exist anywhere in `app/ lib/ config/ test/`: `current_repo`, `current_repo_base`, `session[:rbrun_repo]`, `rbrun_repo_base`, `RepositoriesController#switch`, the `repos/switch` route / `switch_repo_path`, the sidebar `_repo_switcher` partial. A grep gate in the final task enforces this.
- After JS/Tailwind changes run `bun run build` (regenerates `app/assets/builds/rbrun/rbrun.{js,css}`).
- Engine migrations n/a (no schema). Commit messages end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: `Composer::RepoBadge` component (editable pill ⇄ locked chip)

**Files:**
- Create: `app/components/rbrun/composer/repo_badge/component.rb`
- Create: `app/components/rbrun/composer/repo_badge/component.html.erb`
- Test: `test/components/rbrun/composer/repo_badge_test.rb`

**Interfaces:**
- Produces: `Rbrun::Composer::RepoBadge::Component.new(session: nil)`.
  - `#editable?` → `session.nil? || session.messages.none?`.
  - `#repo` / `#base` → from `session&.worktree` (nil when session nil).
  - Editable render: a `data-controller="repo-badge"` wrapper with hidden `repo`/`base` inputs, a picker **trigger** (link to `/repos` targeting `#modal`), a `label`, and a `clear` ✕ (hidden when no repo).
  - Locked render: a read-only chip showing `repo` (or "No repository"), no trigger, no ✕.

- [ ] **Step 1: Write the failing component test**

Create `test/components/rbrun/composer/repo_badge_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class Composer::RepoBadgeTest < ViewComponent::TestCase
    def render_badge(session:) = render_inline(Rbrun::Composer::RepoBadge::Component.new(session:))

    test "no session (root) → editable: picker trigger + hidden fields, no ✕" do
      render_badge(session: nil)
      assert_selector "[data-controller='repo-badge']"
      assert_selector "input[type=hidden][name='repo']", visible: false
      assert_selector "input[type=hidden][name='base']", visible: false
      assert_selector "a[data-turbo-frame='modal']" # opens the picker
      assert_no_selector "[data-action='repo-badge#clear']:not(.hidden)"
    end

    test "a session with no turns is still editable" do
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/web")
      s  = wt.sessions.create!
      render_badge(session: s)
      assert_selector "[data-controller='repo-badge']"
      assert_selector "a[data-turbo-frame='modal']"
    end

    test "a session with a turn → locked: read-only repo chip, no trigger, no ✕" do
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/web")
      s  = wt.sessions.create!
      s.messages.create!(role: "user", event_type: "text", content: "go")
      render_badge(session: s)
      assert_no_selector "[data-controller='repo-badge']"
      assert_no_selector "a[data-turbo-frame='modal']"
      assert_text "acme/web"
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/components/rbrun/composer/repo_badge_test.rb`
Expected: FAIL — `uninitialized constant Rbrun::Composer::RepoBadge`.

- [ ] **Step 3: Implement the component**

Create `app/components/rbrun/composer/repo_badge/component.rb`:

```ruby
module Rbrun
  module Composer
    module RepoBadge
      # The composer's repo selector. Editable while a chat has no turns (opens the switcher dialog,
      # writes hidden repo/base into the compose form via the repo-badge Stimulus controller); locked
      # (read-only chip) once the chat has started. No global scope — the repo is a per-form field.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(session: nil)
          @session = session
        end

        def editable? = @session.nil? || @session.messages.none?
        def repo = @session&.worktree&.repo.presence
        def base = @session&.worktree&.base.presence
      end
    end
  end
end
```

Create `app/components/rbrun/composer/repo_badge/component.html.erb`:

```erb
<% if editable? %>
  <div class="inline-flex items-center gap-1" data-controller="repo-badge">
    <input type="hidden" name="repo" value="<%= repo %>" data-repo-badge-target="repo">
    <input type="hidden" name="base" value="<%= base %>" data-repo-badge-target="base">
    <%= link_to rbrun.repos_path, data: { turbo_frame: "modal" },
          class: "inline-flex items-center gap-1.5 rounded-full border border-slate-200 bg-white px-2.5 py-1 text-xs text-slate-600 hover:bg-slate-50" do %>
      <%= lucide_icon("github", class: "size-3.5 text-slate-400") %>
      <span data-repo-badge-target="label"><%= repo || "Select a repository" %></span>
    <% end %>
    <button type="button" data-action="repo-badge#clear" data-repo-badge-target="clear"
            class="text-slate-400 hover:text-slate-600 <%= "hidden" unless repo %>" aria-label="Clear repository">
      <%= lucide_icon("x", class: "size-3.5") %>
    </button>
  </div>
<% else %>
  <span class="inline-flex items-center gap-1.5 rounded-full bg-slate-100 px-2.5 py-1 text-xs text-slate-500">
    <%= lucide_icon("github", class: "size-3.5 text-slate-400") %>
    <%= repo || "No repository" %>
  </span>
<% end %>
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bin/rails test test/components/rbrun/composer/repo_badge_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/components/rbrun/composer/repo_badge test/components/rbrun/composer/repo_badge_test.rb
git commit -m "feat(composer): RepoBadge — editable picker pill ⇄ locked chip

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The swap — retarget the picker, new create/index, remove all `current_repo` plumbing

This is the atomic refactor: `current_repo` is load-bearing, so its removal, the new create/index, the retargeted picker, and the affected tests all move together.

**Files:**
- Create: `app/javascript/rbrun/controllers/repo_badge_controller.js`
- Create: `app/javascript/rbrun/controllers/repo_choices_controller.js`
- Modify: `app/javascript/rbrun/rbrun.js` (register both)
- Modify: `app/views/rbrun/repositories/_results.html.erb` (rows → client-side pick)
- Modify: `app/views/rbrun/repositories/index.html.erb` (drop `current:` active-marking)
- Delete: `app/controllers/rbrun/repositories_controller.rb`'s `switch` action
- Modify: `config/routes.rb` (remove `repos/switch`)
- Modify: `app/controllers/concerns/rbrun/authentication.rb` (remove `current_repo`/`current_repo_base` + helper_method)
- Delete: `app/views/layouts/rbrun/_repo_switcher.html.erb`
- Modify: `app/views/layouts/rbrun/application.html.erb` (remove the switcher mount)
- Modify: `app/controllers/rbrun/sessions_controller.rb` (new `create`, grouped `index`, drop `worktree_for`)
- Modify: `app/views/rbrun/sessions/index.html.erb` (root composer + grouped worktree list)
- Modify: `app/views/rbrun/messages/_form.html.erb` (locked badge)
- Modify: `app/components/rbrun/ui/menu/component.rb` (doc comment: drop `switch_repo_path`)
- Modify: `app/helpers/rbrun/application_helper.rb` (doc comment: drop "current_repo seam")
- Test: rewrite `test/controllers/rbrun/repositories_test.rb`; migrate `test/controllers/rbrun/sessions_flow_test.rb`, `workflow_decision_flow_test.rb`, `ask_user_flow_test.rb`, `workflow_band_test.rb`, `secrets_flow_test.rb`

**Interfaces:**
- Consumes: `Rbrun::Composer::RepoBadge` (Task 1); `AgentTurnJob.perform_later(session_id, content)`.
- Produces: `SessionsController#create` reads `params[:repo]`/`params[:base]` + `params[:message][:content]` → **new** `Worktree` + `Session` + first turn; `#index` assigns `@worktrees` grouped by repo. Event contract: a picker row dispatches `window` `"rbrun:repo-selected"` `{detail: {repo, base}}`; `repo-badge` consumes it.

- [ ] **Step 1: Write / migrate the failing controller tests**

Rewrite `test/controllers/rbrun/repositories_test.rb` — **delete** the four `switch`-based tests (`switch sets the session repo…`, `the current repo is marked active…`, `switching with a blank repo…`, and any assertion of `aria-current` from a switch). Keep the search/index tests. Add:

```ruby
test "result rows are client-side picks (no switch href, carry repo+base data)" do
  get "/rbrun/repos"
  assert_response :success
  assert_select "[data-action*='repo-choices#pick'][data-repo][data-base]"
  assert_select "a[href*='repos/switch']", count: 0
end
```

In `test/controllers/rbrun/sessions_flow_test.rb`, apply the migration (see the **Test-migration checklist** at the end of this task) — the key new behaviors:

```ruby
test "composing from root creates a NEW worktree + session + first turn" do
  assert_difference([ "Rbrun::Worktree.count", "Rbrun::Session.count" ], 1) do
    assert_enqueued_with(job: Rbrun::AgentTurnJob) do
      post "/rbrun/c", params: { repo: "acme/web", base: "main", message: { content: "hello" } }
    end
  end
  s = Rbrun::Session.order(:id).last
  assert_equal "acme/web", s.worktree.repo
  assert_redirected_to "/rbrun/c/#{s.id}"
end

test "composing again on the same repo makes a SECOND worktree (new every time)" do
  post "/rbrun/c", params: { repo: "acme/web", base: "main", message: { content: "a" } }
  assert_difference("Rbrun::Worktree.count", 1) do
    post "/rbrun/c", params: { repo: "acme/web", base: "main", message: { content: "b" } }
  end
end

test "composing with no repo creates a bare worktree" do
  post "/rbrun/c", params: { message: { content: "no repo" } }
  assert Rbrun::Session.order(:id).last.worktree.bare?
end

test "the index lists worktrees grouped by repo" do
  a = Rbrun::Worktree.create!(tenant: "rbrun", repo: "acme/web")
  a.sessions.create!(kind: :user)
  get "/rbrun/c"
  assert_response :success
  assert_select "*", text: /acme\/web/
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bin/rails test test/controllers/rbrun/sessions_flow_test.rb test/controllers/rbrun/repositories_test.rb`
Expected: FAIL (new create signature / grouped index / no switch not yet built).

- [ ] **Step 3: Register the two Stimulus controllers**

Create `app/javascript/rbrun/controllers/repo_badge_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Lives on the composer's RepoBadge. Consumes a client-side pick (window "rbrun:repo-selected") and
// writes it into the compose form's hidden repo/base fields; the ✕ clears them. No global scope.
export default class extends Controller {
  static targets = ["repo", "base", "label", "clear"]

  connect() {
    this.onSelect = this.onSelect.bind(this)
    window.addEventListener("rbrun:repo-selected", this.onSelect)
  }
  disconnect() { window.removeEventListener("rbrun:repo-selected", this.onSelect) }

  onSelect(event) {
    const { repo, base } = event.detail
    this.repoTarget.value = repo
    this.baseTarget.value = base || ""
    this.labelTarget.textContent = repo
    this.clearTarget.classList.remove("hidden")
  }

  clear(event) {
    event.preventDefault()
    this.repoTarget.value = ""
    this.baseTarget.value = ""
    this.labelTarget.textContent = "Select a repository"
    this.clearTarget.classList.add("hidden")
  }
}
```

Create `app/javascript/rbrun/controllers/repo_choices_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Wraps the switcher dialog's result rows. A pick dispatches the selection to the composer badge and
// closes the modal — no POST, no global cookie.
export default class extends Controller {
  pick(event) {
    event.preventDefault()
    const el = event.currentTarget
    window.dispatchEvent(new CustomEvent("rbrun:repo-selected", {
      detail: { repo: el.dataset.repo, base: el.dataset.base }
    }))
    const modal = document.getElementById("modal")
    if (modal) modal.replaceChildren() // close the dialog by emptying its frame
  }
}
```

Register both in `app/javascript/rbrun/rbrun.js` (import + `application.register("repo-badge", RepoBadgeController)` and `application.register("repo-choices", RepoChoicesController)`), matching the existing pattern.

- [ ] **Step 4: Retarget the picker rows**

Rewrite `app/views/rbrun/repositories/_results.html.erb` — the rows become non-navigating picks under a `repo-choices` controller (locals: `repos`; drop `current`):

```erb
<%# Result rows — client-side picks: each dispatches its repo/base to the composer badge (repo-choices),
    no POST, no global scope. Rendered inside #repo_results. Locals: repos ([GithubRepos::Repo]). %>
<% if repos.any? %>
  <div role="menu" class="p-1.5" data-controller="menu repo-choices" data-action="keydown->menu#navigate">
    <% repos.each do |repo| %>
      <% org, name = repo.full_name.split("/", 2) %>
      <%= component("list_item", title: repo.full_name, subtitle: org,
            avatar: name.to_s[0, 2].upcase,
            data: { action: "repo-choices#pick", repo: repo.full_name, base: repo.default_branch }) %>
    <% end %>
  </div>
<% else %>
  <p class="px-3 py-6 text-center text-sm text-slate-400">No repositories found.</p>
<% end %>
```

Note: `list_item` with **no `href`** already renders a clickable `<div role="menuitem" …>` and forwards `data:` — so the pick works with no primitive change. (The row is a `menuitem` div; `repo-choices#pick` fires on click.)

Update `app/views/rbrun/repositories/index.html.erb`: `render "rbrun/repositories/results", repos: @repos` (drop `current: current_repo`).

- [ ] **Step 5: Remove the switch action, route, cookie, and `current_repo`**

- `app/controllers/rbrun/repositories_controller.rb`: delete the `switch` action (keep `index`). Update the class comment (drop "sets the session-backed current_repo").
- `config/routes.rb`: delete `post "repos/switch", …, as: :switch_repo`.
- `app/controllers/concerns/rbrun/authentication.rb`: delete `current_repo` and `current_repo_base`, and remove them from the `helper_method` list (leave `current_user`, `current_tenant`).
- `app/components/rbrun/ui/menu/component.rb`: in the doc comment, replace the `switch_repo_path` example line with a neutral `href: "#"` example.
- `app/helpers/rbrun/application_helper.rb`: drop the "Mirrors the current_repo seam" sentence.

- [ ] **Step 6: Remove the sidebar switcher**

- Delete `app/views/layouts/rbrun/_repo_switcher.html.erb`.
- `app/views/layouts/rbrun/application.html.erb`: remove the `<%= render "layouts/rbrun/repo_switcher" %>` line and its comment.

- [ ] **Step 7: New `SessionsController` (create + grouped index)**

Rewrite `app/controllers/rbrun/sessions_controller.rb`:

```ruby
module Rbrun
  # Conversations. The index is the tenant's worktrees grouped by repo (open one → its sessions).
  # Composing from root creates a NEW worktree for the chosen repo (bare when none) + a session + the
  # first turn. Repo is a per-chat choice from the composer, never a global scope.
  class SessionsController < Rbrun::ApplicationController
    def index
      @worktrees = Rbrun::Worktree.for_tenant(current_tenant).order(:repo, created_at: :desc)
    end

    def show
      @session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
    end

    def create
      content = params.dig(:message, :content).to_s
      return head(:bad_request) if content.blank?

      repo = params[:repo].to_s.strip.presence
      base = params[:base].to_s.strip.presence
      # `repo` is NOT NULL — a bare (no-repo) worktree carries repo "" (same shape SkillScenarioRun uses).
      worktree = repo ? Rbrun::Worktree.create!(tenant: current_tenant, repo:, base: base || "main")
                      : Rbrun::Worktree.create!(tenant: current_tenant, repo: "", bare: true)
      session = worktree.sessions.create!
      AgentTurnJob.perform_later(session.id, content)
      redirect_to rbrun.session_path(session)
    end

    def retry
      session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
      ResumeTurnJob.perform_later(session.id)
      redirect_to rbrun.session_path(session)
    end
  end
end
```

(`worktree_for` is gone — new worktree every time, per the design.)

- [ ] **Step 8: Root page — composer + grouped worktree list**

Rewrite `app/views/rbrun/sessions/index.html.erb`: a compose form (message + `custom("composer/repo_badge", session: nil)`) above the worktrees grouped by repo. Each worktree links to its sessions (`rbrun.worktree_path(worktree)` — added in Task 3; until then link to the worktree's latest session or leave a placeholder `#`). Group by `repo`; bare (nil repo) under "Scratch". Compose form:

```erb
<%= form_with url: rbrun.sessions_path, method: :post, class: "flex flex-col gap-2 rounded-xl border border-slate-200 p-3" do %>
  <%= component("textarea", label: nil, name: "message[content]", rows: 3, placeholder: "Start a new conversation…") %>
  <div class="flex items-center justify-between">
    <%= custom("composer/repo_badge", session: nil) %>
    <%= component("button", type: "submit", variant: :primary, size: :sm) { "Start" } %>
  </div>
<% end %>
```

(Grouped list markup: iterate `@worktrees.group_by(&:repo)`, a header per repo, rows per worktree.)

- [ ] **Step 9: In-chat composer shows the locked badge**

In `app/views/rbrun/messages/_form.html.erb`, render `custom("composer/repo_badge", session: session)` in the composer footer (it renders **locked** because the session has turns) so the chat always shows its bound repo.

- [ ] **Step 10: Register JS assets, migrate the remaining flow tests, run**

Run `bun run build`. Then apply the **Test-migration checklist** below and run the affected suites.

**Removal checklist (grep must return nothing in `app/ lib/ config/`):**
- [ ] `current_repo`  [ ] `current_repo_base`  [ ] `session[:rbrun_repo]` / `rbrun_repo_base`
- [ ] `repos/switch` / `switch_repo` / `def switch`  [ ] `_repo_switcher` (file + mount)  [ ] `#repo_switcher` / `#repo_label`

**Test-migration checklist (remove the `POST /repos/switch` setup line; adjust bodies):**
- [ ] `sessions_flow_test.rb` — remove `/repos/switch` from setup; replace the "index scoped to current repo", "creating a conversation", "finds-or-creates the worktree", "with no current repo", and the two "repo switcher trigger" tests with the Step-1 grouped-index + new-create + bare tests. Keep the message-post/approval tests (they use `@session` directly).
- [ ] `workflow_decision_flow_test.rb` — delete the `/repos/switch` setup line (the test drives `@session` directly; confirm green).
- [ ] `ask_user_flow_test.rb` — same.
- [ ] `workflow_band_test.rb` — same.
- [ ] `secrets_flow_test.rb` — same.
- [ ] `repositories_test.rb` — done in Step 1 (switch tests removed, pick-retarget asserted).

Run: `bin/rails test test/controllers/rbrun/`
Expected: PASS.

- [ ] **Step 11: Full suite + lint + commit**

Run: `bin/rails test && bin/rubocop -a`
Expected: green; clean.

```bash
git add -A
git commit -m "refactor(repo): repo picked in the composer — remove the global current_repo trap

RepoBadge writes hidden repo/base into the compose form; the switcher dialog's
rows are retargeted to client-side picks (window event) — no POST, no cookie.
Composing from root creates a NEW worktree (bare when no repo) + first turn.
Index becomes worktrees grouped by repo. Removes switch action/route/cookie,
current_repo/_base, and the sidebar switcher.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `worktrees#show` — a worktree's sessions

**Files:**
- Modify: `config/routes.rb` (`resources :worktrees, only: :show`)
- Create: `app/controllers/rbrun/worktrees_controller.rb`
- Create: `app/views/rbrun/worktrees/show.html.erb`
- Modify: `app/views/rbrun/sessions/index.html.erb` (worktree rows link to `worktree_path`)
- Test: `test/controllers/rbrun/worktrees_flow_test.rb`

**Interfaces:**
- Produces: `GET /worktrees/:id` → the worktree's `:user` sessions (excludes `:skill_scenario`).

- [ ] **Step 1: Failing test**

```ruby
require "test_helper"
module Rbrun
  class WorktreesFlowTest < ActionDispatch::IntegrationTest
    setup { post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" } }

    test "show lists the worktree's user sessions and excludes skill_scenario" do
      wt = Rbrun::Worktree.create!(tenant: "rbrun", repo: "acme/web")
      u  = wt.sessions.create!(kind: :user)
      m  = wt.sessions.create!(kind: :skill_scenario)
      get "/rbrun/worktrees/#{wt.id}"
      assert_response :success
      assert_select "a[href=?]", "/rbrun/c/#{u.id}"
      assert_select "a[href=?]", "/rbrun/c/#{m.id}", count: 0
    end
  end
end
```

- [ ] **Step 2: Run → fail.** `bin/rails test test/controllers/rbrun/worktrees_flow_test.rb`

- [ ] **Step 3: Route + controller + view**

`config/routes.rb`: add `resources :worktrees, only: :show`.

`app/controllers/rbrun/worktrees_controller.rb`:

```ruby
module Rbrun
  class WorktreesController < Rbrun::ApplicationController
    def show
      @worktree = Rbrun::Worktree.for_tenant(current_tenant).find(params[:id])
      @sessions = @worktree.sessions.where(kind: "user").order(created_at: :desc)
    end
  end
end
```

`app/views/rbrun/worktrees/show.html.erb`: a `surface` titled `@worktree.repo` (or "Scratch"), listing `@sessions` as links to `session_path` (reuse the row markup from the old index).

- [ ] **Step 4: Link the grouped index rows** to `rbrun.worktree_path(worktree)` in `sessions/index.html.erb`.

- [ ] **Step 5: Run → pass; full suite.** `bin/rails test`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(worktrees): worktrees#show — a worktree's user sessions

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: System test, dogfood, and the ghost sweep

**Files:**
- Rewrite: `test/system/rbrun/repo_switcher_test.rb` → the composer badge flow
- Modify: `lib/tasks/rbrun/dogfood/repo_switcher.rake` (drive the new badge flow, or retire if superseded)

**Interfaces:** end-to-end verification in a real browser + the ghost-grep gate.

- [ ] **Step 1: Rewrite the system test** (`test/system/rbrun/repo_switcher_test.rb`)

Reuse the `FakeRepos` DI from the existing test. New scenario: from the root page, open the badge picker, pick a repo (badge label fills to `owner/name`, ✕ appears), type a first message, submit → lands on the chat, and the in-chat badge is **locked** (read-only chip, no picker trigger, no ✕). Assert `js_errors: true` stays clean.

```ruby
test "pick a repo in the composer, start a chat, repo locks" do
  visit "/rbrun/c"
  find("[data-controller='repo-badge'] a[data-turbo-frame='modal']").click
  assert_selector "dialog[open] h2", text: "Switch repository"
  find("[data-action*='repo-choices#pick']", text: "rbdotrun/rbrun").click
  assert_no_selector "dialog[open]"
  within("[data-controller='repo-badge']") { assert_text "rbdotrun/rbrun" }
  fill_in "message[content]", with: "kick off"
  click_button "Start"
  assert_selector "#composer" # landed in the chat
  assert_no_selector "[data-controller='repo-badge'] a[data-turbo-frame='modal']" # locked
  assert_text "rbdotrun/rbrun"
end
```

- [ ] **Step 2: Run the system test.** `bin/rails test:system test/system/rbrun/repo_switcher_test.rb` (build assets first if not already). Expected: PASS.

- [ ] **Step 3: Update the dogfood** — `lib/tasks/rbrun/dogfood/repo_switcher.rake` currently drives the sidebar switcher → `switch_repo` href. Retarget it to the composer badge flow (open picker, pick, assert the badge filled), or if the system test fully covers it, retire the file and note it in the commit. Keep dogfood rules: one scenario per file, no ENV toggles.

- [ ] **Step 4: The ghost sweep (the "clean" gate)**

Run:
```bash
grep -rn "current_repo\|current_repo_base\|rbrun_repo\|repos/switch\|switch_repo\|_repo_switcher\|repo_switcher\b" app/ lib/ config/ test/ | grep -v "/log/"
```
Expected: **no matches** except the retargeted `repo_choices`/`repo-badge` names and (if kept) the renamed dogfood. Any `current_repo`/switch ghost is a bug — fix it.

- [ ] **Step 5: Full suite + system + lint**

Run: `bin/rails test && bin/rails test:system && bin/rubocop -a`
Expected: all green, clean.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "test(repo): system test for composer repo selection + retire the switcher dogfood path

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (against the spec)

- **Coverage:** badge (T1); composer selection + retargeted picker + new create + grouped index + full `current_repo`/switch/cookie/sidebar removal + flow-test migration (T2); worktrees#show (T3); system test + dogfood + ghost-grep gate (T4). Matches the spec's four slices.
- **Clean-refactor mandate:** explicit **Removal checklist**, **Test-migration checklist**, and a final **grep gate** — no `current_repo` ghost survives.
- **Invariants:** `Worktree → repo` unchanged, no schema; primitives only (list_item extended with `as: :button`, not inlined); repo is a per-chat input resolved to a worktree, then locked.
- **Type consistency:** `create` reads `params[:repo]`/`params[:base]` + `params[:message][:content]`; the badge posts hidden `repo`/`base`; the `rbrun:repo-selected` `{repo, base}` event contract is the same in `repo_choices` (dispatch) and `repo_badge` (consume).
- **Placeholders:** none. Verified against the code: `list_item` with no `href` already renders a clickable `menuitem` div (no extension), and `rbrun_worktrees.repo` is `NOT NULL` (bare worktree uses `repo: ""`). The only free-form bit is the grouped-list markup in `sessions/index` (iterate `@worktrees.group_by(&:repo)`, "" → "Scratch").
