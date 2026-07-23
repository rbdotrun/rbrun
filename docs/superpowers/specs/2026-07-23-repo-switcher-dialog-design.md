# Repo Switcher Dialog — Design

> Feature spec. Rebuilds the sidebar repo switcher's **presentation** on rbrun's Dialog primitive.
> Supersedes §3 ("dropdown") of `2026-07-19-repo-workspace-switcher-design.md` — the **data layer,
> controller, routes, service, and result rows are unchanged**; only how the switcher opens and lazy-
> loads changes. One spec → one plan → branch → TDD → dogfood → PR, same cadence as the phases.

**Goal:** Clicking the sidebar repo switcher (visually unchanged) opens a **centered dialog** that
**lazy-fetches** the repo list over Turbo and lets the user **search/filter** it, then pick one.

**One-line contract:** the trigger is a link into the layout's singleton `#modal` frame; **one Turbo
request** renders the dialog shell (title + search box + a `loading: :lazy` `#repo_results` frame whose
inline block is a **skeleton**); the lazy frame's own request fetches repos from GitHub (recent repos
on open, `GithubRepos#search` on every debounced keystroke); picking a row POSTs `switch_repo` and
full-navigates away, tearing down the modal.

This is a **presentation rebuild**, not a new feature: `Rbrun::GithubRepos`, `current_repo`,
`RepositoriesController#switch`, the `repos`/`switch_repo` routes, and `repositories/_results.html.erb`
all stay as they are. The switcher was already a **TEMP disabled stub** carrying the note "being
rebuilt on a real Dialog primitive" — this is that rebuild.

---

## 1. Why a dialog (not the original dropdown)

The committed spec (`2026-07-19-repo-workspace-switcher-design.md` §3) designed the switcher as a
`dropdown` panel anchored below the logo. The team subsequently ported a full **Dialog primitive**
(`Rbrun::Ui::Dialog` + `Rbrun::Ui::DialogFrame` + the `overlay` controller) and stubbed the switcher
pending a rebuild on it. This spec commits to the dialog: a centered modal is a better host for a
searchable, lazy-loading list (more room, focus-trapped, keyboard-native `<dialog>`), and it reuses the
already-shipped modal plumbing instead of the floating-panel machinery.

The pattern is modeled on `../sources/fizzy`'s searchable lazy dialog (`my/_menu.html.erb` +
`dialog_controller.js`): **open the dialog instantly, show a placeholder, stream the real rows into a
`loading: :lazy` Turbo frame.**

---

## 2. Flow (two requests, both cheap; open is instant)

```
click trigger  ──(req #1: Turbo-Frame: modal)──►  RepositoriesController#index
  └─ renders the DIALOG SHELL into <turbo-frame id="modal">   ← NO GitHub call, instant
       ├─ dialog_frame(title: "Switch repository")
       ├─ search <input>            (command controller)
       └─ <turbo-frame id="repo_results" src="/repos" loading="lazy">
            └─ SKELETON rows (animate-pulse)                  ← shown immediately
  overlay controller opens the <dialog> the moment #modal fills

lazy frame fires ──(req #2: Turbo-Frame: repo_results)──►  RepositoriesController#index
  └─ GithubRepos#search(query: "")  → recent repos → repositories/_results (menu rows)
       replaces the skeleton

type in search  ──(debounced, command controller repoints frame.src=/repos?q=…)──►  req #2 again
  └─ GithubRepos#search(query: q)   → filtered repos → _results
       skeleton re-shows while [aria-busy]

pick a row (POST switch_repo, data-turbo-frame="_top")
  └─ session[:rbrun_repo] = owner/name → redirect to scoped /c → full nav tears down the modal
```

**"One Turbo to open the dialog; it contains the lazy Turbo frame fetching the repos."** Request #1 is
trivial (no network) so the dialog pops open instantly over the skeleton; request #2 carries the GitHub
latency *behind* the skeleton. This is the only shape that yields a real skeleton on first open.

---

## 3. Controller — one route, two render paths

`RepositoriesController#index` branches on the **requesting frame id** (`request.headers["Turbo-Frame"]`,
which Turbo sets to the DOM id of the frame that issued the navigation):

- **`"modal"`** → render the **dialog shell** (`repositories/dialog.html.erb`, through `dialog_frame`).
  **No `GithubRepos` call.** Layout-less (frame request).
- **`"repo_results"`** (or anything else / absent) → the **existing results path**:
  `@repos = Rbrun.github_repos(current_tenant).search(query: params[:q].to_s)` → `repositories/index`
  (the `#repo_results` frame wrapping `_results`). Layout-less on frame requests, as today.

Defaulting the non-`modal` case to results keeps the current controller tests (which issue a plain
`GET /rbrun/repos` with no `Turbo-Frame` header) green and unchanged. A tiny helper on
`ApplicationController` exposes the id:

```ruby
def turbo_frame_id = request.headers["Turbo-Frame"].presence
```

`#switch` is untouched.

---

## 4. Views

### 4.1 Trigger — `app/views/layouts/rbrun/_repo_switcher.html.erb` (rewrite the stub)

A `link_to rbrun.repos_path, data: { turbo_frame: "modal" }` with the **exact current visual
treatment** (border/bg/padding/shadow, the `group-data-[collapsed]/sidebar:*` collapse classes, the
`github` leading icon + trailing `chevrons-up-down`). Differences from the stub: it's a link (not a
`disabled` button), and the label span (`id="repo_label"`) shows `current_repo` (`owner/name`) when set,
falling back to the muted "Select a repository". Keeps `id="repo_switcher"` so sidebar/dogfood selectors
survive. `#repo_label` is a stable id so a future tool broadcast could redraw the face in place.

### 4.2 Dialog shell — `app/views/rbrun/repositories/dialog.html.erb` (new)

```erb
<%= component("dialog_frame", title: "Switch repository") do %>
  <div class="mt-4 w-[28rem] max-w-full"
       data-controller="command"
       data-command-url-value="<%= rbrun.repos_path %>">
    <%# search box — wired to the existing command controller (debounce → frame.src) %>
    <input type="text" name="q" autocomplete="off" placeholder="Search repositories…"
           data-command-target="input" data-action="input->command#search"
           class="form-input-base …">
    <%= turbo_frame_tag "repo_results", src: rbrun.repos_path, loading: :lazy,
                        data: { command_target: "frame" } do %>
      <%= render "rbrun/repositories/skeleton" %>
    <% end %>
  </div>
<% end %>
```

- The search `<input>` renders **inside req #1** (instant), so the box is usable immediately.
- The `#repo_results` frame is `loading: :lazy` with the **skeleton as its inline block** — visible until
  req #2 lands. `command` controller focuses the input on open (its existing IntersectionObserver) and
  repoints `frame.src` on debounced input.

### 4.3 Skeleton — `app/views/rbrun/repositories/_skeleton.html.erb` (new)

~6 shimmer rows (`animate-pulse` + `bg-slate-100` bars, avatar square + name bar) matching a
`_results` menu row's height, so the swap doesn't jump. Reused as the `[aria-busy]` state during search
(§5).

### 4.4 Rows — a new `list_item` component + `_results` two-line rows

Repo rows are **two-line**: a leading **avatar spanning both rows**, a **title** (`owner/name`, the full
path) and a **subtitle** (the owning **org** = `owner`, the segment before `/`). All derivable from
`full_name` — **`GithubRepos` and its `Repo` struct are untouched** (no API/data change).

**New primitive `Rbrun::Ui::ListItem::Component`** (`app/components/rbrun/ui/list_item/component.rb`) —
a reusable, keyboard-reachable two-line row:

```
component("list_item", title:, subtitle:, avatar:, href:, active:, **attrs)
```

- Renders an `<a role="menuitem" tabindex="-1" data-menu-target="item">` (so it drops straight into a
  `role="menu"` container and inherits `menu_controller` roving-tabindex nav), or a `<div>` when no
  `href`. Layout: leading avatar (`self-stretch`/centered, spans both text rows) · a stacked
  title (medium, truncate) + subtitle (xs, muted, truncate) · optional trailing check when `active`.
- `active` → `aria-current="true"` + the active background (mirrors `menu`'s `Link`), so the current
  repo reads the same as before. `**attrs` carries `data:` (e.g. `turbo_method: :post`, `turbo_frame`).

**`_results.html.erb`** renders a `role="menu"` container (`data-controller="menu"
data-action="keydown->menu#navigate"`, matching `Ui::Menu`'s wrapper) looping `list_item` rows:

```erb
<div role="menu" class="p-1" data-controller="menu" data-action="keydown->menu#navigate">
  <% repos.each do |repo| %>
    <% org, name = repo.full_name.split("/", 2) %>
    <%= component("list_item",
          title: repo.full_name, subtitle: org,
          avatar: name.to_s[0, 2].upcase,
          href: rbrun.switch_repo_path(repo: repo.full_name, base: repo.default_branch),
          active: (repo.full_name == current),
          data: { turbo_method: :post, turbo_frame: "_top" }) %>
  <% end %>
</div>
```

The `switch_repo` POST + `data-turbo-frame="_top"` full-nav + `aria-current` behavior is unchanged from
the old `menu`-link rows — the existing controller tests (`a[aria-current="true"]`, `a text: owner/name`)
still pass, now against `list_item` anchors. The skeleton (§4.3) mirrors this two-line shape (avatar
square + two stacked bars).

---

## 5. Stimulus / JS (reuse; no new controller)

- **`command_controller.js`** — reused verbatim (`input`/`frame` targets, `url` value, debounce →
  `frame.src = /repos?q=…`, focus-on-reveal). It already owns exactly the search behavior.
- **`overlay_controller.js`** — reused: opens the singleton `<dialog>` when `#modal` fills, closes on
  Esc / backdrop / when the frame empties. No change.
- **`menu_controller.js`** — reused inside `_results` for roving-tabindex keyboard nav over the rows.
- **Skeleton-during-search:** while a search request is in flight the `#repo_results` frame carries
  `[aria-busy]`; a small CSS rule (dim the stale list, or re-reveal a skeleton overlay) covers the gap.
  Kept to CSS — no JS added. (If CSS-only proves insufficient, `command#search` may swap the skeleton in
  before setting `src`; decided during implementation, not a new controller.)

No `@floating-ui/dom` needed for the switcher anymore (the dialog is centered, not anchored) — it stays
in the bundle for the footer user-menu dropdown, untouched.

---

## 6. Tests

- **`test/controllers/rbrun/repositories_test.rb`** (extend): a request with header `Turbo-Frame: modal`
  renders the **shell** (asserts the `command` search input + a `turbo-frame#repo_results[loading=lazy]`
  with a `src`) and makes **no** `GithubRepos` call (the DI fake records no query); a request with
  `Turbo-Frame: repo_results` renders the GitHub rows. Existing tests (no header → results) stay green.
- **`test/system/rbrun/repo_switcher_test.rb`** (new, Cuprite via `application_system_test_case.rb`,
  `Rbrun.github_repos` stubbed): click the trigger → dialog opens with the skeleton → rows appear →
  typing repoints the frame and narrows the list → picking a row updates the trigger face and scopes the
  conversation index. Fills the currently-empty `test/system/`.
- **`test/components/rbrun/ui_primitives_test.rb`**: add the new `list_item` primitive to the smoke
  test (render with title/subtitle/avatar/active → assert `role="menuitem"`, both text lines, and the
  `aria-current` active marker).

## 7. Dogfood — `lib/tasks/rbrun/dogfood/repo_switcher.rake` (update selectors)

Retarget the existing scenario from the dropdown selectors to the dialog: click `#repo_switcher a`
(the trigger) → assert the `<dialog[open]>` with the skeleton, then the streamed rows → type in
`[data-command-target="input"]` → real GitHub results narrow → pick → face (`#repo_label`) updates and
the index scopes. Still one non-variabilized scenario, gated on `.env` `GITHUB_PAT`, screenshots to
`tmp/dogfood/`. (§8 collapse-rail checks unchanged.)

---

## 8. Spec/plan reconciliation

- Amend `2026-07-19-repo-workspace-switcher-design.md` §3: the switcher face opens a **dialog**
  (this spec), not a dropdown; the command-menu content (search → lazy `#repo_results` → rows) is the
  same. Add a pointer to this file.
- The original plan's Task 5 (`…repo-workspace-switcher.md`) already built the controller/routes/service/
  `command` controller/results — those tasks stand. Only the switcher **partial + open mechanism** are
  re-done here; note it in the plan.

## 9. Inherited invariants (verbatim)

- No registry / no self-registration (#1).
- All outbound HTTP = Faraday on async-http — `GithubRepos` unchanged (#5).
- Tenancy always-on; `current_repo` session-scoped **within** the tenant (#8).
- Dogfood never variabilized; one scenario per file (#6).
- RubyLLM engine-only; nothing here touches a sub-gem (#9).
