# Repo Workspace Switcher — Design

> Feature spec, post-Phase-8. Extends the rbrun engine design (`2026-07-19-rbrun-design.md`). One
> spec → one just-in-time plan → branch → TDD → dogfood → PR, same cadence as the phases.

**Goal:** Give rbrun a left sidebar with a **repo switcher** below the logo — the workspace you act
in. The sidebar is a collapsible rail _shell_ with well-defined _behaviours_; the switcher's _content_
is the repo universe.

**One-line contract:** The **repo is the workspace**. It is **session-backed**, **not a new table**.
The switcher is a `dropdown` shell hosting a **command-menu** (a search box → filtered list → keyboard
nav, implemented in Stimulus) whose rows are fed by **server-side GitHub search** via the config
`github_pat`.

---

## 1. Concept: what "workspace" is

The switchable workspace in rbrun is the **Repo**. rbrun has two workspace-like axes — they are
**not** the same:

| axis                            | role                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------- |
| **Repo** (session-backed)       | the workspace you act in — _this is what the dropdown switches_                 |
| **Tenant** (`c.tenancy_key` slug) | always-on isolation key, **config-defined, never user-switched** (invariant #8) |

```
Tenant   (isolation, from config)
└─ Repo   (workspace — session-backed)      ← dropdown below the logo
   └─ Worktree (one branch + one sandbox)
      └─ Session  (one conversation)
```

**No `Repo` table.** A repo is identified by its GitHub `full_name` (`owner/name`). `current_repo` is
a session string (`session[:rbrun_repo]`), session-backed like any other current-workspace selector.
A repo's conversations are the Sessions whose Worktree carries that `repo` string, within the tenant.
"Recent repos" come for free from
`Worktree.for_tenant(t).distinct.pluck(:repo)`; the full universe comes from GitHub on demand.

This retires the hardcoded `default_worktree` / `RBRUN_WORKTREE_REPO` fallback in
`SessionsController`.

---

## 2. The sidebar shell (behaviours fixed; only content differs)

These pieces live in rbrun's DSL (`Rbrun::Ui::*`, `Rbrun::ApplicationViewComponent`, the `component()`
helper) and Stimulus registry. rbrun uses `Rbrun::Ui::` + `Rbrun::ApplicationViewComponent` +
`helpers.class_names` (or `cn` for tailwind-merge).

### 2.1 Components (`app/components/rbrun/ui/…`)

- **`dropdown`** — trigger + floating panel; `renders_one :trigger`,
  `renders_one :menu, Rbrun::Ui::Menu::Component`. `placement`/`offset`/`trigger_class`/`panel_class`.
  Positioning + open/close/outside-press/Escape/focus owned by the `dropdown` Stimulus controller.
- **`menu`** — `renders_many :items` with `link`/`current`/`header`/
  `separator` builders (`m.link`, `m.current`, `m.header`, `m.separator`). Each link is
  `role="menuitem"` + `data-menu-target="item"`; `avatar:`/`icon:`/`active:`/`disabled:` supported.
- **`nav_item`** — icon + label row; auto-active via `current_page?`;
  the collapse fade classes (`group-data-[collapsed]/sidebar:*`).
- **`nav_group`** — group heading that swaps to a 1px rule when the
  rail is collapsed.

### 2.2 Stimulus controllers (`app/javascript/rbrun/controllers/…`, registered in `rbrun.js`)

- **`sidebar`** — `data-collapsed` is the single source of
  truth; `data-ready` gated after two rAFs to kill the Turbo open→closed flash; state persisted in the
  `sidebar_collapsed` cookie so the **server renders collapsed markup directly**.
- **`dropdown`** — **depends on `@floating-ui/dom`** —
  add it to `package.json` devDeps and the bun bundle. Owns visibility, floating position
  (offset/flip/shift + autoUpdate), outside-press dismiss, Escape, focus return, focus-first-item.
- **`menu`** — roving-tabindex WAI-ARIA keyboard nav;
  IntersectionObserver resets to the first item when the menu becomes visible.

### 2.3 Layout + header

- **`_sidebar_header`** — rbrun logo/wordmark +
  collapsed mark + rail-hover toggler + the panel toggle button. Collapse mechanics driven by
  `data-action="sidebar#toggle"`. (rbrun ships a simple wordmark; no SVG logo asset required — a text
  mark with the same three-face collapse behaviour is acceptable.)
- **`layouts/rbrun/application.html.erb`** — the
  `group/sidebar` shell: `w-64 ↔ w-16`, `data-controller="sidebar"`, `data-collapsed` from the cookie.
  Regions top→bottom: **header** (`_sidebar_header`) · **repo switcher** (§3) · **nav**
  (`nav_item "Conversations"`) · **footer user menu** (dropdown opening upward → email + sign out).
  `<main>` renders `yield`.

### 2.4 Explicitly OUT of scope (app-shell extras, not the sidebar)

`account_meter` (billing/quota), `drawer`/`dialog`/`confirm_dialog`, the `#flash` toast surface, the
`turbo_stream_from "user_#{id}"` user stream, and any extra nav groups. None are
part of "the sidebar shell + behaviours"; they can come later if wanted.

---

## 3. The repo switcher content (the ONE dynamic piece)

rbrun's repo universe is unbounded (the PAT "sees everything"), so the switcher's _content_ is a
**command-menu**: a search box → filtered list → check on current → keyboard nav, implemented in
Stimulus (rbrun has no React/`cmdk`), fed by **server-side GitHub search**.

- **Face (trigger):** current repo as `owner/name` + `chevrons-up-down`, or _"Select a repository"_
  when none is chosen (the empty state). Rendered via the `dropdown` trigger
  slot; broadcast-target-friendly (`id="repo_label"`) so a future tool could redraw it in place.
- **Panel:** a search `<input>` (autofocused on open) + a Turbo-frame result list of `menu` items.
- **`command` Stimulus controller** (small): debounces input (~200ms) and drives the Turbo request
  that swaps the result list. Keyboard nav is the `menu` controller. This is the only genuinely new
  JS; it owns the query and feeds the list, without React.
- **Data:** `Rbrun::GithubRepos` service (§4) → `search(query:)`. Empty query returns recent/updated
  repos; a query hits GitHub search. Rows are `owner/name` (+ `default_branch`, `private`).
- **Choosing a repo** → sets `session[:rbrun_repo]`, records nothing in the DB, redirects to the repo's
  conversation index. `base` for any worktree under it is the repo's `default_branch` from GitHub
  (not a hardcoded "main").

---

## 4. `Rbrun::GithubRepos` service

Pure service in the engine (`app/services/rbrun/github_repos.rb`). **Faraday on the async-http
adapter** (invariant #5), auth'd with `Rbrun.config.github_pat`.

```
Rbrun::GithubRepos.new(pat: Rbrun.config.github_pat)
  #list(per_page: 30)          -> [Repo]  # GET /user/repos?sort=updated&affiliation=owner,collaborator,organization_member
  #search(query:, per_page: 30) -> [Repo] # blank query → #list; else GET /search/repositories?q=<query>+fork:true (scoped to the token's access)
```

`Repo` = a plain Struct/Data `full_name`, `default_branch`, `private`. Fail-fast on a missing PAT
(consistent with adapters validating their own config). No caching in v1 (debounced client keeps
volume low); a short TTL cache is a later optimization.

---

## 5. Controllers, routes, plumbing

- **`current_repo` in `Rbrun::Authentication`** — add a `current_repo` helper (`session[:rbrun_repo]`),
  `helper_method`. No auth change; tenancy still comes from `current_user.tenant`.
- **`Rbrun::RepositoriesController`**
  - `GET /repos` (`index`) — the command-menu result list (Turbo frame); `params[:q]` → `GithubRepos#search`.
  - `POST /repos/switch` — body `{ repo: "owner/name" }` → set `session[:rbrun_repo]`, redirect to
    `sessions_path`. (`turbo_method: :post`.)
- **`Rbrun::SessionsController`**
  - `index` — scope to `current_repo`: `Session.for_tenant(t).joins(:worktree).where(rbrun_worktrees: { repo: current_repo })`. Empty/prompt state when `current_repo` is nil.
  - `create` — replace `default_worktree` with `worktree_for(current_repo)`:
    `Worktree.for_tenant(t).find_or_create_by!(repo: current_repo) { |w| w.base = default_branch }`.
    Guard: no `current_repo` → redirect to index with a "pick a repo first" state.
- **Routes:** two explicit routes — `get "repos", to: "repositories#index", as: :repos` (the
  command-menu result frame) and `post "repos/switch", to: "repositories#switch", as: :switch_repo`.

---

## 6. Bundle

- `package.json` devDeps += **`@floating-ui/dom`** (required by the `dropdown` controller). No `cmdk`,
  no React.
- `rbrun.js` registers `sidebar`, `dropdown`, `menu`, `command` alongside the existing
  `autoscroll`/`composer`/`sticky-details`.
- `bun run build` re-emits `app/assets/builds/rbrun/{rbrun.js,rbrun.css}` (Tailwind v4 auto-scans the
  new component/partial classes).

---

## 7. Dogfood gate — `dogfood/repo_switcher.rake`

One real, non-variabilized scenario (creds from `.env`: `GITHUB_PAT` at minimum; Daytona/Anthropic if
it drives a turn). Headless browser (Capybara + Cuprite, as `dogfood/browser.rake`):

1. sign in → the sidebar renders with the repo switcher below the logo.
2. open the switcher → type a query → **server-side GitHub results** populate the command-menu.
3. pick a repo → the face updates to `owner/name`, the conversation index scopes to it.
4. collapse the rail (`sidebar#toggle`) → `w-16`, labels fade, cookie set, **no flash**; reload stays
   collapsed (server-rendered).
5. ✓/✗ + screenshots to `tmp/dogfood`.

A phase-style acceptance gate: green when a real GitHub-backed switch works end to end in the browser.

---

## 8. Global constraints (inherited, verbatim)

- No registry, no self-registration (invariant #1).
- All outbound HTTP = Faraday on async-http (invariant #5) — `GithubRepos` included.
- Tenancy always-on; every record carries the tenant slug (invariant #8). `current_repo` is
  session-scoped **within** the tenant.
- Dogfood is never variabilized; one scenario per file (invariant #6).
- RubyLLM stays engine-only; the new service touches neither sub-gem (invariant #9).

```

```
