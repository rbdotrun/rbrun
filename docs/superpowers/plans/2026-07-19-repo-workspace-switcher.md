# Repo Workspace Switcher — Implementation Plan

> **For agentic workers:** execute task-by-task, TDD. Steps use `- [ ]`. Spec:
> `docs/superpowers/specs/2026-07-19-repo-workspace-switcher-design.md`.

**Goal:** Left sidebar with a repo switcher below the logo — faithful port of insitix's sidebar
shell/behaviours, content swapped orgs→repos; repo = session-backed workspace; switcher fed by
server-side GitHub search.

**Tech:** ViewComponent (`Rbrun::Ui::*` DSL), Stimulus (+ `@floating-ui/dom`), Turbo frames, Faraday
on async-http, minitest (DI, no mocks), bun bundle.

## Global Constraints (verbatim from spec §8)
- No registry / no self-registration.
- All outbound HTTP = Faraday on async-http.
- Tenancy always-on; `current_repo` is session-scoped **within** the tenant.
- Dogfood never variabilized; one scenario per file.
- RubyLLM engine-only; the new service touches neither sub-gem.

---

### Task 1 — `menu` + `dropdown` components + controllers + floating-ui

**Files:** Create `app/components/rbrun/ui/menu/component.rb`, `app/components/rbrun/ui/dropdown/component.rb`,
`app/javascript/rbrun/controllers/{menu,dropdown}_controller.js`; Modify `package.json` (+`@floating-ui/dom`),
`app/javascript/rbrun/rbrun.js`; Test `test/components/rbrun/menu_dropdown_test.rb`.

**Interfaces produced:** `Rbrun::Ui::Menu::Component` (`m.link/current/header/separator`),
`Rbrun::Ui::Dropdown::Component` (`renders_one :trigger`, `renders_one :menu`).

- [ ] Port `Primitives::Menu` → `Rbrun::Ui::Menu::Component` (namespace + `helpers.class_names`/`safe_join`; keep item classes verbatim). Nested item classes as inner ViewComponents rendered via `call`.
- [ ] Port `Primitives::Dropdown` → `Rbrun::Ui::Dropdown::Component` (`renders_one :menu, Rbrun::Ui::Menu::Component`; erb_template with the `data-controller="dropdown"` contract).
- [ ] Port `menu_controller.js` + `dropdown_controller.js` verbatim; register both in `rbrun.js`; add `@floating-ui/dom` to devDeps + `bun add`.
- [ ] Test: render a dropdown with trigger + `m.current`/`m.link`/`m.separator`; assert `role="menu"`, `role="menuitem"`, `data-dropdown-target`, active check icon.
- [ ] `bin/rails test test/components/rbrun/menu_dropdown_test.rb`, rubocop, commit.

### Task 2 — `nav_item` + `nav_group`

**Files:** Create `app/components/rbrun/ui/nav_item/component.rb`, `app/components/rbrun/ui/nav_group/component.rb`;
Test append to `test/components/rbrun/menu_dropdown_test.rb`.

- [ ] Port both verbatim (namespace + `helpers.class_names`/`helpers.current_page?`/`helpers.lucide_icon`; keep collapse fade classes exact).
- [ ] Test: nav_item active (explicit `active: true`) → `aria-current="page"` + ACTIVE classes; nav_group renders label + the collapsed 1px LINE span.
- [ ] test, rubocop, commit.

### Task 3 — `sidebar` controller + `_sidebar_header` + rail layout

**Files:** Create `app/javascript/rbrun/controllers/sidebar_controller.js`,
`app/views/layouts/rbrun/_sidebar_header.html.erb`; Modify `app/views/layouts/rbrun/application.html.erb`,
`rbrun.js`; Test extend `test/controllers/rbrun/sessions_flow_test.rb`.

**Interfaces consumed:** Task 1/2 components. **Produced:** the `group/sidebar` shell.

- [ ] Port `sidebar_controller.js` verbatim; register in `rbrun.js`.
- [ ] `_sidebar_header`: rbrun wordmark + collapsed mark + rail-hover toggler + toggle button; same `sidebar#toggle` actions + collapse classes (text mark, no SVG).
- [ ] Rewrite `application.html.erb`: `group/sidebar w-64 data-[collapsed]:w-16`, `data-controller="sidebar"`, `data-collapsed` from `cookies[:sidebar_collapsed]`. Regions: header · repo-switcher placeholder (Task 5) · `nav_item "Conversations"` · footer user-menu dropdown (email + sign out). `<main>` = yield.
- [ ] Test: signed-in `GET /rbrun/c` renders `#navbar[data-controller="sidebar"]`, the Conversations nav_item, the footer email; with `sidebar_collapsed=1` cookie the element has `data-collapsed`.
- [ ] test, rubocop, commit.

### Task 4 — `Rbrun::GithubRepos` service

**Files:** Create `app/services/rbrun/github_repos.rb`; Test `test/services/rbrun/github_repos_test.rb`.

**Interfaces produced:** `Rbrun::GithubRepos.new(pat:, conn: nil)` with `#list(per_page:)` and
`#search(query:, per_page:)` → `[Rbrun::GithubRepos::Repo(full_name, default_branch, private)]`.

- [ ] Implement with a Faraday connection (`f.response :json`, `Authorization: Bearer <pat>`, `f.adapter :async_http`), injectable via `conn:` for tests. Raise `ArgumentError` on blank pat. `#search` blank query → `#list`; else `GET /search/repositories?q=<query>` (map `.items`); `#list` → `GET /user/repos?sort=updated&affiliation=owner,collaborator,organization_member`.
- [ ] Test with `Faraday.new { |f| f.adapter :test, stubs }`: stub `/user/repos` → list maps full_name/default_branch/private; stub `/search/repositories` → search maps `.items`; blank pat raises.
- [ ] `bin/rails test test/services/rbrun/github_repos_test.rb`, rubocop, commit.

### Task 5 — repo switcher: current_repo + controller + routes + command controller + partial

**Files:** Create `app/controllers/rbrun/repositories_controller.rb`,
`app/views/rbrun/repositories/index.html.erb`, `app/views/layouts/rbrun/_repo_switcher.html.erb`,
`app/javascript/rbrun/controllers/command_controller.js`; Modify
`app/controllers/concerns/rbrun/authentication.rb`, `config/routes.rb`, `lib/rbrun.rb` (seam),
`application.html.erb` (mount switcher), `rbrun.js`; Test `test/controllers/rbrun/repositories_test.rb`.

**Interfaces produced:** `current_repo` helper; `Rbrun.github_repos` seam (overridable in tests);
`repos_path`, `switch_repo_path`.

- [ ] `Rbrun.github_repos` module method → `GithubRepos.new(pat: config.github_pat)`, memo + writer for test injection (mirror `current_user_resolver`).
- [ ] `Authentication#current_repo` (`session[:rbrun_repo]`) + `helper_method`.
- [ ] `RepositoriesController#index` (Turbo frame `repo_results`; `params[:q]` → `Rbrun.github_repos.search`) rendering `menu` items (each `m.link full_name, href: '#', data: { action: 'command#pick', repo: full_name }` active when == current_repo). `#switch` (POST) → `session[:rbrun_repo] = params[:repo]`; redirect `sessions_path`.
- [ ] Routes: `get "repos", to: "repositories#index", as: :repos`; `post "repos/switch", to: "repositories#switch", as: :switch_repo`.
- [ ] `command_controller.js`: debounce input → `frame.src = repos_path?q=...`; `pick` → POST to switch (a hidden form / `fetch` with turbo). Register in `rbrun.js`.
- [ ] `_repo_switcher`: `dropdown` with trigger = `#repo_label` (current_repo or "Select a repository" + chevrons-up-down); panel = search input (`command#input`) + `<turbo-frame id="repo_results">`. Mount in `application.html.erb`.
- [ ] Test (inject a fake into `Rbrun.github_repos`): `GET /rbrun/repos?q=rb` renders the fake's results; `POST /rbrun/repos/switch repo=a/b` sets session + redirects to index.
- [ ] test, rubocop, commit.

### Task 6 — Sessions scoped to current_repo

**Files:** Modify `app/controllers/rbrun/sessions_controller.rb`; Test extend
`test/controllers/rbrun/sessions_flow_test.rb`.

- [ ] `index`: when `current_repo` present, scope `Session.for_tenant(t).joins(:worktree).where(rbrun_worktrees: { repo: current_repo })`; else empty + "pick a repo" state.
- [ ] `create`: replace `default_worktree` with `Worktree.for_tenant(t).find_or_create_by!(repo: current_repo)`; no `current_repo` → redirect to index (no create). Drop the `RBRUN_WORKTREE_REPO`/`"rbdotrun/scratch"` fallback.
- [ ] Test: with `session[:rbrun_repo]` set, index shows only that repo's sessions; create builds a worktree with that repo; without it, create redirects and adds nothing.
- [ ] test, rubocop, commit.

### Task 7 — bundle

**Files:** Modify none (registration done in prior tasks); run build.

- [ ] `bun run build`; assert `rbrun.js` bundles `menu`/`dropdown`/`sidebar`/`command` + `@floating-ui`.
- [ ] Full `bin/rails test` + `bin/rubocop`; commit the rebuilt bundle.

### Task 8 — dogfood `repo_switcher.rake`

**Files:** Create `lib/tasks/rbrun/dogfood/repo_switcher.rake`.

- [ ] Headless (Capybara+Cuprite) like `browser.rake`; gate on `.env` `GITHUB_PAT`. Sign in → sidebar renders → open switcher → type query → server-side results populate → pick a repo → face updates + index scoped → collapse rail (no flash, cookie) → reload stays collapsed. ✓/✗ + screenshots. Never variabilized.
- [ ] `bin/rails app:dogfood:repo_switcher` loads + aborts clean without creds; rubocop; commit.

---

## Self-review
- Spec coverage: §2 shell → T1–T3; §3 switcher → T5; §4 service → T4; §5 plumbing → T5–T6; §6 bundle → T1/T7; §7 dogfood → T8. ✓
- Types consistent: `Rbrun::GithubRepos.new(pat:, conn:)`, `Repo(full_name, default_branch, private)`, `current_repo`, `Rbrun.github_repos` used the same in T4/T5/T6. ✓
