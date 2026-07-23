# Repo Switcher Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking the sidebar repo switcher (visually unchanged) opens a centered dialog that lazy-fetches the repo list over one Turbo frame, with server-side GitHub search and two-line rows (avatar + `owner/name` title + org subtitle).

**Architecture:** The switcher trigger is a `link_to … data: { turbo_frame: "modal" }` into the layout's existing singleton `<dialog>`/`#modal` frame (opened by the `overlay` controller). One Turbo request renders a dialog shell (`dialog_frame` title + search `<input>` on the existing `command` controller + a `loading: :lazy` `#repo_results` frame whose inline block is a skeleton). The lazy frame's own request runs `Rbrun::GithubRepos#search` (recent repos on open, query on debounced keystrokes) and renders rows built from a new `Rbrun::Ui::ListItem::Component`. Picking a row POSTs `switch_repo` with `data-turbo-frame="_top"` (full nav, tears down the modal).

**Tech Stack:** Rails engine, ViewComponent (`Rbrun::Ui::*` DSL), Stimulus (reuses `overlay`/`command`/`menu` — no new controller), Turbo frames, Tailwind v4 (bun build), minitest (DI fakes, no mocks), Cuprite system tests.

## Global Constraints

- No registry / no self-registration (invariant #1).
- All outbound HTTP = Faraday on async-http; `GithubRepos` is **untouched** by this plan (invariant #5).
- Tenancy always-on; `current_repo` is `session[:rbrun_repo]`, session-scoped **within** the tenant (invariant #8).
- Dogfood never variabilized; one scenario per file (invariant #6).
- RubyLLM engine-only; nothing here touches a sub-gem (invariant #9).
- Ruby 3.4.4 / Rails >= 8.1.3. Tests run via `bin/rails test <path>`. Lint via `bin/rubocop`.
- Spec: `docs/superpowers/specs/2026-07-23-repo-switcher-dialog-design.md`.

---

## File Structure

- **Create** `app/components/rbrun/ui/list_item/component.rb` — reusable two-line row (avatar + title + subtitle), renders `<a role="menuitem">` for menu keyboard nav (Task 1).
- **Create** `test/components/rbrun/list_item_test.rb` — focused component test (Task 1).
- **Modify** `test/components/rbrun/ui_primitives_test.rb` — add `list_item` to the smoke test (Task 1).
- **Modify** `app/controllers/rbrun/application_controller.rb` — add `turbo_frame_id` helper (Task 2).
- **Modify** `app/controllers/rbrun/repositories_controller.rb` — branch `index` on the requesting frame (Task 2).
- **Create** `app/views/rbrun/repositories/dialog.html.erb` — the dialog shell (Task 2).
- **Create** `app/views/rbrun/repositories/_skeleton.html.erb` — shimmer placeholder rows (Task 2).
- **Modify** `test/controllers/rbrun/repositories_test.rb` — modal-branch + row assertions (Tasks 2 & 3).
- **Modify** `app/views/rbrun/repositories/_results.html.erb` — two-line `list_item` rows (Task 3).
- **Modify** `app/views/layouts/rbrun/_repo_switcher.html.erb` — enabled trigger + `current_repo` face (Task 4).
- **Modify** `test/controllers/rbrun/sessions_flow_test.rb` — trigger assertions (Task 4).
- **Create** `test/system/rbrun/repo_switcher_test.rb` — full browser flow (Task 5).
- **Modify** `lib/tasks/rbrun/dogfood/repo_switcher.rake` — dialog selectors (Task 6).
- **Modify** `app/assets/builds/rbrun/rbrun.{css,js}` — rebuilt bundle (Task 6).

---

### Task 1: `list_item` two-line row component

**Files:**
- Create: `app/components/rbrun/ui/list_item/component.rb`
- Test: `test/components/rbrun/list_item_test.rb`
- Modify: `test/components/rbrun/ui_primitives_test.rb`

**Interfaces:**
- Consumes: `Rbrun::ApplicationViewComponent` (base), `class_names`, `link_to`, `tag`, `safe_join`, `lucide_icon` (available in components — see `Ui::Menu::Component`'s `Link`).
- Produces: `component("list_item", title:, subtitle: nil, avatar: nil, href: nil, active: false, **attrs)` → an `<a role="menuitem" tabindex="-1" data-menu-target="item">` (or `<div>` when `href` is nil) with a leading avatar and stacked title/subtitle; `active` adds `aria-current="true"` + a trailing check.

- [ ] **Step 1: Write the failing focused test**

Create `test/components/rbrun/list_item_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class ListItemTest < ViewComponent::TestCase
    test "renders a menuitem link with avatar, title, and subtitle" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::ListItem::Component.new(
          title: "rbdotrun/rbrun", subtitle: "rbdotrun", avatar: "RB", href: "/x"
        )).to_html
      end
      assert_match %{role="menuitem"}, html
      assert_match %{data-menu-target="item"}, html
      assert_match "rbdotrun/rbrun", html
      assert_match ">rbdotrun<", html   # the subtitle line
      assert_match "RB", html           # the avatar
    end

    test "active marks aria-current and renders a check" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::ListItem::Component.new(title: "a/b", href: "/x", active: true)).to_html
      end
      assert_match %{aria-current="true"}, html
      assert_match "lucide-check", html
    end

    test "without href renders a non-interactive div" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::ListItem::Component.new(title: "a/b")).to_html
      end
      assert_match %{<div}, html
      assert_match %{role="menuitem"}, html
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/components/rbrun/list_item_test.rb`
Expected: FAIL — `uninitialized constant Rbrun::Ui::ListItem`.

- [ ] **Step 3: Implement the component**

Create `app/components/rbrun/ui/list_item/component.rb`:

```ruby
module Rbrun
  module Ui
    module ListItem
      # A reusable two-line list row: a leading avatar spanning both rows, a title, and a muted
      # subtitle. Renders <a role="menuitem" data-menu-target="item"> so it drops into a role="menu"
      # container and inherits the Menu controller's roving-tabindex keyboard nav (or a <div> when no
      # href). `active` → aria-current + a trailing check, mirroring Ui::Menu's Link.
      class Component < Rbrun::ApplicationViewComponent
        BASE     = "group/li flex items-center gap-2.5 rounded-md px-2.5 py-1.5 focus:outline-none".freeze
        INACTIVE = "hover:bg-slate-100 focus:bg-slate-100".freeze
        ACTIVE   = "bg-slate-100".freeze
        AVATAR   = "flex size-9 shrink-0 items-center justify-center self-center rounded bg-slate-200 text-xs font-semibold text-slate-600".freeze
        TITLE    = "truncate text-sm font-medium text-slate-900".freeze
        SUBTITLE = "truncate text-xs text-slate-500".freeze
        CHECK    = "size-4 shrink-0 self-center text-slate-500".freeze

        def initialize(title:, subtitle: nil, avatar: nil, href: nil, active: false, **attrs)
          @title = title
          @subtitle = subtitle
          @avatar = avatar
          @href = href
          @active = active
          @attrs = attrs
        end

        def call
          data  = { menu_target: "item" }.merge(@attrs.delete(:data) || {})
          klass = class_names(BASE, @active ? ACTIVE : INACTIVE, @attrs.delete(:class))
          body  = safe_join([ leading, text_stack, trailing ].compact)

          if @href
            link_to(@href, role: "menuitem", tabindex: "-1", data:,
                           aria: { current: (@active ? "true" : nil) }, class: klass, **@attrs) { body }
          else
            tag.div(body, role: "menuitem", tabindex: "-1", data: data, class: klass, **@attrs)
          end
        end

        private

        def leading
          tag.span(@avatar, class: AVATAR) if @avatar.present?
        end

        def text_stack
          tag.span(class: "flex min-w-0 flex-1 flex-col") do
            safe_join([
              tag.span(@title, class: TITLE),
              (tag.span(@subtitle, class: SUBTITLE) if @subtitle.present?)
            ].compact)
          end
        end

        def trailing
          lucide_icon("check", class: CHECK) if @active
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run: `bin/rails test test/components/rbrun/list_item_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Add `list_item` to the primitives smoke test**

In `test/components/rbrun/ui_primitives_test.rb`, add this line just after the `Ui::ListCard` assertion (inside the `with_controller_class` block):

```ruby
        assert_match %{role="menuitem"}, render_inline(Ui::ListItem::Component.new(title: "o/n", subtitle: "o", avatar: "ON", href: "/x")).to_html
```

- [ ] **Step 6: Run the smoke test**

Run: `bin/rails test test/components/rbrun/ui_primitives_test.rb`
Expected: PASS.

- [ ] **Step 7: Lint + commit**

```bash
bin/rubocop app/components/rbrun/ui/list_item/component.rb test/components/rbrun/list_item_test.rb
git add app/components/rbrun/ui/list_item test/components/rbrun/list_item_test.rb test/components/rbrun/ui_primitives_test.rb
git commit -m "feat(ui): list_item — two-line row (avatar + title + subtitle) as a menuitem"
```

---

### Task 2: Controller frame-branch + dialog shell + skeleton

**Files:**
- Modify: `app/controllers/rbrun/application_controller.rb`
- Modify: `app/controllers/rbrun/repositories_controller.rb`
- Create: `app/views/rbrun/repositories/dialog.html.erb`
- Create: `app/views/rbrun/repositories/_skeleton.html.erb`
- Test: `test/controllers/rbrun/repositories_test.rb`

**Interfaces:**
- Consumes: `component("dialog_frame", title:)`, the `command` Stimulus controller (`data-controller="command"`, `data-command-url-value`, targets `input`/`frame`), `rbrun.repos_path`.
- Produces: `RepositoriesController#index` renders the **dialog shell** when the requesting frame id is `"modal"`, else the **results frame** (existing behavior). `ApplicationController#turbo_frame_id` → the `Turbo-Frame` request header (or nil).

- [ ] **Step 1: Write the failing controller test**

In `test/controllers/rbrun/repositories_test.rb`, add these tests inside `class RepositoriesTest` (after the existing `"index renders the results frame…"` test):

```ruby
    test "a request from the #modal frame renders the dialog shell without hitting GitHub" do
      get "/rbrun/repos", headers: { "Turbo-Frame" => "modal" }
      assert_response :success
      assert_nil @fake.last_query, "the shell must not call GithubRepos"
      assert_select "h2", text: "Switch repository"
      assert_select "input[data-command-target=?]", "input"
      assert_select "turbo-frame#repo_results[loading=?]", "lazy"
      assert_select "turbo-frame#repo_results[src]"
    end

    test "a request from the #repo_results frame renders the GitHub rows" do
      get "/rbrun/repos", params: { q: "rb" }, headers: { "Turbo-Frame" => "repo_results" }
      assert_response :success
      assert_equal "rb", @fake.last_query
      assert_select "turbo-frame#repo_results"
    end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/rbrun/repositories_test.rb -n "/dialog shell/"`
Expected: FAIL — no `h2 "Switch repository"` (index still renders the results frame for every request).

- [ ] **Step 3: Add the `turbo_frame_id` helper**

In `app/controllers/rbrun/application_controller.rb`, add inside the `private` section (below `turbo_frame_request?`):

```ruby
    # The DOM id of the <turbo-frame> that issued this navigation (Turbo sends it as the Turbo-Frame
    # request header), or nil for a non-frame request. Used to pick which view a shared endpoint renders.
    def turbo_frame_id
      request.headers["Turbo-Frame"].presence
    end
```

- [ ] **Step 4: Branch `index` on the requesting frame**

Replace `RepositoriesController#index` in `app/controllers/rbrun/repositories_controller.rb` with:

```ruby
    def index
      # The switcher trigger targets #modal: render the dialog shell (search box + a lazy #repo_results
      # frame). No GitHub call here — the shell paints instantly over a skeleton, the lazy frame fetches.
      return render(:dialog, layout: false) if turbo_frame_id == "modal"

      # Every other request is the results frame itself (the lazy load + each debounced search).
      @repos = Rbrun.github_repos(current_tenant).search(query: params[:q].to_s)
      render :index, layout: !turbo_frame_request?
    end
```

- [ ] **Step 5: Create the skeleton partial**

Create `app/views/rbrun/repositories/_skeleton.html.erb`:

```erb
<%# Placeholder shown inside the lazy #repo_results frame until the real rows stream in. Mirrors a
    list_item row (avatar square + two stacked bars) so the swap doesn't jump. %>
<div role="menu" class="p-1" aria-busy="true">
  <% 6.times do %>
    <div class="flex items-center gap-2.5 rounded-md px-2.5 py-1.5">
      <div class="size-9 shrink-0 animate-pulse rounded bg-slate-100"></div>
      <div class="flex min-w-0 flex-1 flex-col gap-1.5">
        <div class="h-3.5 w-40 max-w-full animate-pulse rounded bg-slate-100"></div>
        <div class="h-2.5 w-24 max-w-full animate-pulse rounded bg-slate-100"></div>
      </div>
    </div>
  <% end %>
</div>
```

- [ ] **Step 6: Create the dialog shell view**

Create `app/views/rbrun/repositories/dialog.html.erb`:

```erb
<%# The dialog shell loaded into the singleton #modal frame when the switcher is clicked. Renders
    THROUGH dialog_frame (so the header reads like every other modal), then a `command`-controlled
    search box + a lazy #repo_results frame whose placeholder is the skeleton. No GitHub call happens
    to build this — the lazy frame fires its own request (recent repos on open, search on typing). %>
<%= component("dialog_frame", title: "Switch repository") do %>
  <div class="mt-4 w-[28rem] max-w-full"
       data-controller="command" data-command-url-value="<%= rbrun.repos_path %>">
    <input type="text" name="q" autocomplete="off" placeholder="Search repositories…"
           data-command-target="input" data-action="input->command#search"
           class="form-input-base w-full">
    <div class="mt-3 max-h-[52vh] overflow-y-auto">
      <%= turbo_frame_tag "repo_results", src: rbrun.repos_path, loading: :lazy,
                          data: { command_target: "frame" } do %>
        <%= render "rbrun/repositories/skeleton" %>
      <% end %>
    </div>
  </div>
<% end %>
```

- [ ] **Step 7: Run the new controller tests**

Run: `bin/rails test test/controllers/rbrun/repositories_test.rb`
Expected: PASS — the two new tests pass and the four existing tests still pass (they send no `Turbo-Frame` header → results branch, unchanged).

- [ ] **Step 8: Lint + commit**

```bash
bin/rubocop app/controllers/rbrun/application_controller.rb app/controllers/rbrun/repositories_controller.rb
git add app/controllers/rbrun/application_controller.rb app/controllers/rbrun/repositories_controller.rb app/views/rbrun/repositories/dialog.html.erb app/views/rbrun/repositories/_skeleton.html.erb test/controllers/rbrun/repositories_test.rb
git commit -m "feat(repos): open the switcher as a dialog — lazy #repo_results frame + skeleton"
```

---

### Task 3: Two-line `list_item` result rows

**Files:**
- Modify: `app/views/rbrun/repositories/_results.html.erb`
- Test: `test/controllers/rbrun/repositories_test.rb`

**Interfaces:**
- Consumes: `component("list_item", …)` (Task 1); `rbrun.switch_repo_path`; `current_repo` (via the `current:` local already passed by `index.html.erb`).
- Produces: `_results` renders a `role="menu"` container of two-line rows — title `owner/name`, subtitle `owner`, avatar = repo-name initials — each a `switch_repo` POST that full-navigates.

- [ ] **Step 1: Write the failing assertions**

In `test/controllers/rbrun/repositories_test.rb`, extend the existing `"index renders the results frame with the searched repos"` test with subtitle + menu assertions (add these lines before its final `end`):

```ruby
      assert_select "div[role=menu]"
      assert_select "a[role=menuitem]", minimum: 2
      # The subtitle line carries the org (owner) segment.
      assert_select "a[role=menuitem] span", text: "rbdotrun"
      assert_select "a[role=menuitem] span", text: "acme"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/rbrun/repositories_test.rb -n "/results frame with the searched/"`
Expected: FAIL — the current `_results` renders `component("menu")` links (single-line, no `role=menuitem` subtitle span for the org).

- [ ] **Step 3: Rewrite `_results` with `list_item` rows**

Replace the whole of `app/views/rbrun/repositories/_results.html.erb` with:

```erb
<%# The repo rows — a role="menu" list of two-line list_items (Menu controller drives keyboard nav).
    title = owner/name, subtitle = owner (the org), avatar = repo-name initials. Each row POSTs to
    switch_repo and full-navigates (data-turbo-frame="_top"), the current repo marked active.
    Rendered inside the #repo_results Turbo frame. Locals: repos ([GithubRepos::Repo]), current (str). %>
<% if repos.any? %>
  <div role="menu" class="p-1" data-controller="menu" data-action="keydown->menu#navigate">
    <% repos.each do |repo| %>
      <% org, name = repo.full_name.split("/", 2) %>
      <%= component("list_item",
            title: repo.full_name,
            subtitle: org,
            avatar: name.to_s[0, 2].upcase,
            href: rbrun.switch_repo_path(repo: repo.full_name, base: repo.default_branch),
            active: (repo.full_name == current),
            data: { turbo_method: :post, turbo_frame: "_top" }) %>
    <% end %>
  </div>
<% else %>
  <p class="px-3 py-6 text-center text-sm text-slate-400">No repositories found.</p>
<% end %>
```

- [ ] **Step 4: Run the repositories controller tests**

Run: `bin/rails test test/controllers/rbrun/repositories_test.rb`
Expected: PASS — the extended test passes; the `aria-current="true"` / `text: /owner\/name/` assertions in the other tests still pass (the title span carries `owner/name`; the active anchor still has `aria-current`).

- [ ] **Step 5: Lint + commit**

```bash
bin/rubocop
git add app/views/rbrun/repositories/_results.html.erb test/controllers/rbrun/repositories_test.rb
git commit -m "feat(repos): two-line result rows — owner/name title + org subtitle + avatar"
```

---

### Task 4: Enable the sidebar trigger (opens the dialog, shows current_repo)

**Files:**
- Modify: `app/views/layouts/rbrun/_repo_switcher.html.erb`
- Test: `test/controllers/rbrun/sessions_flow_test.rb`

**Interfaces:**
- Consumes: `rbrun.repos_path`, `current_repo` (helper), `lucide_icon`; the layout's singleton `#modal` frame + `overlay` controller (opens when `#modal` fills).
- Produces: `#repo_switcher` contains a `link_to repos_path, data: { turbo_frame: "modal" }` whose label (`#repo_label`) shows `current_repo` or "Select a repository".

- [ ] **Step 1: Write the failing test**

In `test/controllers/rbrun/sessions_flow_test.rb`, add a test after `"the collapsible sidebar rail renders with its regions"` (the `setup` already switches to repo `"a/b"`, so `current_repo` is `"a/b"`):

```ruby
    test "the repo switcher trigger opens the modal and shows the current repo" do
      get "/rbrun/c"
      assert_response :success
      assert_select "#repo_switcher a[href$=?][data-turbo-frame=?]", "/repos", "modal"
      assert_select "#repo_label", text: "a/b"
    end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/controllers/rbrun/sessions_flow_test.rb -n "/switcher trigger opens the modal/"`
Expected: FAIL — the stub is a `disabled` button with static "Select a repository" and no `#repo_label`/link.

- [ ] **Step 3: Rewrite the trigger partial**

Replace the whole of `app/views/layouts/rbrun/_repo_switcher.html.erb` with:

```erb
<%# The repo switcher face. Visually identical to the prior stub, but now an enabled link: clicking
    loads the dialog shell into the singleton #modal frame (the overlay controller opens the dialog).
    The label (#repo_label) shows the session-backed current_repo, or the muted empty state. %>
<div id="repo_switcher">
  <%= link_to rbrun.repos_path, data: { turbo_frame: "modal" },
        class: "flex w-full items-center gap-2 rounded-md border bg-white px-2 py-1.5 text-left text-sm shadow-xs transition-colors hover:bg-slate-50 group-data-[collapsed]/sidebar:pl-[7px]" do %>
    <span class="flex size-6 shrink-0 items-center justify-center rounded bg-slate-100 text-slate-400"><%= lucide_icon("github", class: "size-3.5") %></span>
    <span id="repo_label" class="flex-1 truncate group-data-[collapsed]/sidebar:opacity-0 <%= current_repo.present? ? "text-slate-700" : "text-slate-400" %>">
      <%= current_repo.presence || "Select a repository" %>
    </span>
    <%= lucide_icon("chevrons-up-down", class: "size-4 shrink-0 text-slate-400 group-data-[collapsed]/sidebar:opacity-0") %>
  <% end %>
</div>
```

- [ ] **Step 4: Run the sidebar tests**

Run: `bin/rails test test/controllers/rbrun/sessions_flow_test.rb`
Expected: PASS — the new test passes; `"the collapsible sidebar rail renders with its regions"` still passes (`#repo_switcher` still present).

- [ ] **Step 5: Lint + commit**

```bash
bin/rubocop
git add app/views/layouts/rbrun/_repo_switcher.html.erb test/controllers/rbrun/sessions_flow_test.rb
git commit -m "feat(repos): enable the switcher trigger — opens the dialog, shows current_repo"
```

---

### Task 5: System test — the full browser flow

**Files:**
- Create: `test/system/rbrun/repo_switcher_test.rb`

**Interfaces:**
- Consumes: `ApplicationSystemTestCase` (Cuprite), `Rbrun.github_repos=` DI seam, the routes/views from Tasks 1–4.

- [ ] **Step 1: Write the system test**

Create `test/system/rbrun/repo_switcher_test.rb`:

```ruby
require "application_system_test_case"

module Rbrun
  class RepoSwitcherTest < ApplicationSystemTestCase
    # A DI fake for the repo directory — returns fixed repos, records the query. No network.
    class FakeRepos
      Repo = Struct.new(:full_name, :default_branch, :private)
      attr_reader :last_query

      def initialize(repos) = @repos = repos
      def search(query:)
        @last_query = query
        return @repos if query.to_s.strip.empty?

        @repos.select { |r| r.full_name.include?(query) }
      end
    end

    setup do
      Rbrun.github_repos = FakeRepos.new([
        FakeRepos::Repo.new("rbdotrun/rbrun", "main", false),
        FakeRepos::Repo.new("acme/api", "develop", true)
      ])
      # Sign in through the real login form so the session cookie is set in the browser.
      visit "/rbrun/login"
      fill_in "email", with: "dev@rbrun.test"
      fill_in "password", with: "password"
      click_button "Sign in"
    end

    teardown { Rbrun.github_repos = nil }

    test "opening the switcher lazy-loads repos, filters, and picks one" do
      visit "/rbrun/c"

      # The trigger is present; the dialog is not open yet.
      assert_selector "#repo_switcher a"
      assert_no_selector "dialog[open]"

      # Open the dialog — the shell paints instantly, the lazy frame streams the rows in.
      find("#repo_switcher a").click
      assert_selector "dialog[open]"
      assert_selector "dialog[open] h2", text: "Switch repository"
      assert_selector "turbo-frame#repo_results a[role=menuitem]", text: "rbdotrun/rbrun"
      assert_selector "turbo-frame#repo_results a[role=menuitem]", text: "acme/api"

      # Typing narrows the server-side list.
      fill_in "q", with: "acme"
      assert_selector "turbo-frame#repo_results a[role=menuitem]", text: "acme/api"
      assert_no_selector "turbo-frame#repo_results a[role=menuitem]", text: "rbdotrun/rbrun"

      # Picking a repo full-navigates and updates the trigger face.
      find("a[role=menuitem]", text: "acme/api").click
      assert_no_selector "dialog[open]"
      assert_selector "#repo_label", text: "acme/api"
    end
  end
end
```

- [ ] **Step 2: Run the system test**

Run: `bin/rails test:system test/system/rbrun/repo_switcher_test.rb`
Expected: PASS. (If the lazy `#repo_results` frame does not fetch on open in headless Chrome, the fix is one line — flip the frame to eager when the `command` controller connects: add `this.frameTarget.loading = "eager"` at the end of `command_controller.js#connect`, guarded by `if (this.hasFrameTarget)`. Re-run.)

- [ ] **Step 3: Commit**

```bash
git add test/system/rbrun/repo_switcher_test.rb app/javascript/rbrun/controllers/command_controller.js
git commit -m "test(system): repo switcher dialog — open, lazy-load, filter, pick"
```

---

### Task 6: Dogfood selectors + rebuild the bundle

**Files:**
- Modify: `lib/tasks/rbrun/dogfood/repo_switcher.rake`
- Modify: `app/assets/builds/rbrun/rbrun.css`, `app/assets/builds/rbrun/rbrun.js` (regenerated)

**Interfaces:**
- Consumes: the shipped dialog UI (Tasks 1–4); `bun run build`.

- [ ] **Step 1: Read the current dogfood scenario**

Run: `sed -n '1,200p' lib/tasks/rbrun/dogfood/repo_switcher.rake` — locate the interaction block that clicks the dropdown trigger (`[data-dropdown-target='trigger']`), types into `[data-command-target='input']`, and reads `#repo_label` / `#repo_results`.

- [ ] **Step 2: Retarget the selectors to the dialog**

Update the scenario's interaction steps to the dialog flow (keep everything else — sign-in, the collapse-rail checks, screenshots, the `.env GITHUB_PAT` gate — unchanged):
- Open: `find("#repo_switcher a").click` then wait for `assert_selector "dialog[open]"` (was: click the dropdown trigger).
- Skeleton→rows: assert the skeleton is replaced by `turbo-frame#repo_results a[role=menuitem]` (real GitHub rows).
- Search: `fill_in "q", with: "<a real repo the PAT can see>"` (the input still carries `data-command-target="input"`), assert the row appears.
- Pick: `find("a[role=menuitem]", text: "<owner/name>").click`; assert `dialog[open]` is gone and `#repo_label` shows the picked `owner/name`.

- [ ] **Step 3: Verify the dogfood loads and aborts clean without creds**

Run: `bin/rails app:dogfood:repo_switcher` (with no `GITHUB_PAT` in `.env`)
Expected: it loads and aborts cleanly with the "needs GITHUB_PAT" message (no Ruby error). With creds present it drives the real flow green.

- [ ] **Step 4: Rebuild the bundle**

Run: `bun run build`
Expected: re-emits `app/assets/builds/rbrun/{rbrun.js,rbrun.css}`; Tailwind v4 picks up the new `list_item`/skeleton/dialog classes. No new Stimulus controller is registered (the switcher reuses `overlay`/`command`/`menu`).

- [ ] **Step 5: Full suite + lint**

Run: `bin/rails test && bin/rubocop`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add lib/tasks/rbrun/dogfood/repo_switcher.rake app/assets/builds/rbrun/rbrun.css app/assets/builds/rbrun/rbrun.js
git commit -m "chore(repos): dialog dogfood selectors + rebuilt bundle"
```

---

## Self-Review

**Spec coverage:**
- §2 flow (1 req opens dialog, lazy frame fetches) → Task 2. ✓
- §3 controller frame-branch → Task 2. ✓
- §4.1 trigger (visually unchanged, current_repo face) → Task 4. ✓
- §4.2 dialog shell (dialog_frame + command search + lazy frame + skeleton) → Task 2. ✓
- §4.3 skeleton → Task 2. ✓
- §4.4 `list_item` component + two-line rows → Tasks 1 & 3. ✓
- §5 reuse overlay/command/menu, no new controller (+ eager fallback note) → Tasks 2 & 5. ✓
- §6 tests (controller modal/results, system, smoke) → Tasks 1, 2, 3, 5. ✓
- §7 dogfood selectors → Task 6. ✓
- §8/§9 spec reconciliation + invariants → `GithubRepos`/`switch`/routes untouched; verified across all tasks. ✓

**Placeholder scan:** No TBD/TODO. The one deferred item (eager-frame fallback) is a complete, conditional one-line fix with exact code, not a placeholder. The dogfood retarget (Task 6) uses the existing scenario's real repo/creds rather than inventing values. ✓

**Type consistency:** `component("list_item", title:, subtitle:, avatar:, href:, active:, data:)` is defined identically in Task 1 and consumed in Task 3. `turbo_frame_id` defined (Task 2) and used (Task 2). `#repo_results`, `#modal`, `#repo_label`, `data-turbo-frame`, `data-command-target` spellings match across Tasks 2/4/5/6. Repo fields (`full_name`, `default_branch`) match `GithubRepos::Repo`. ✓
