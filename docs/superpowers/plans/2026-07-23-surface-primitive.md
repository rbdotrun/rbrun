# Surface Primitive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the one invariant titled/scrollable panel into `Rbrun::Ui::Surface`, then route `page`, `dialog_frame`, `drawer_panel`, `confirm_dialog`, and `card` through it — deleting the duplicated header/body/footer markup.

**Architecture:** `Surface` is a flex-column primitive with **no height of its own** (`flex min-h-0 min-w-0 flex-auto flex-col`); header/footer are `flex-shrink-0`, the body is `min-h-0 flex-1 overflow-y-auto`. Placed as a flex child of a height-bearing flex-column container (the `<dialog>`/drawer/`<main>`, made flex-col with the height passing through the `<turbo-frame>`), the body scrolls; with no constraint the surface grows and nothing scrolls. Chrome (radius/border/bg) + elevation move onto the surface via `preset:`/`elevation:` presets; the `<dialog>` shells go bare.

**Tech Stack:** ViewComponent (`Rbrun::Ui::*` DSL, `StyleVariants`, `cn`), Tailwind v4 (bun build), Turbo frames, minitest, Cuprite system test.

## Global Constraints
- **Primitives-first** (CLAUDE.md banner): this IS that work — one primitive, composed everywhere. No hand-rolled panel markup left behind.
- No registry / no self-registration (#1); RubyLLM engine-only (#9) — untouched.
- Tailwind scans `components/rbrun/**` + `views/**` (the corrected `@source`); rebuild the bundle after class changes.
- Ruby 3.4.4 / Rails >= 8.1.3. Tests: `bin/rails test <path>` and `bin/rails test:system <path>`. Lint: `bin/rubocop` (`-a` autofix).
- Spec: `docs/superpowers/specs/2026-07-23-surface-primitive-design.md`.
- **App stays working at every commit:** a `<dialog>` shell only goes bare in the SAME task that migrates its frame content to the (chrome-bearing) surface.

---

## File Structure
- **Create** `app/components/rbrun/ui/surface/component.rb` + `component.html.erb` — the primitive (Task 1).
- **Create** `test/components/rbrun/surface_test.rb` (Task 1).
- **Modify** `test/components/rbrun/ui_primitives_test.rb` — add `surface` (Task 1).
- **Modify** `app/components/rbrun/ui/dialog/component.rb`, `app/components/rbrun/ui/dialog_frame/component.{rb,html.erb}` (Task 2).
- **Modify** `app/components/rbrun/ui/drawer/component.rb`, `app/components/rbrun/ui/drawer_panel/component.rb` (Task 3).
- **Modify** `app/components/rbrun/ui/confirm_dialog/component.{rb,html.erb}` (Task 4).
- **Modify** `app/views/layouts/rbrun/application.html.erb` (`<main>`), `app/views/rbrun/sessions/{index,show}.html.erb`, `app/views/rbrun/skills/index.html.erb`; **Delete** `app/components/rbrun/page/*`, `app/components/rbrun/page_header/*` (Task 5).
- **Modify** `app/components/rbrun/ui/card/component.rb`, `app/views/rbrun/auth/sessions/new.html.erb` (Task 6).
- **Modify** `app/assets/builds/rbrun/rbrun.{css,js}` (Task 7).

---

### Task 1: `Surface` primitive

**Files:**
- Create: `app/components/rbrun/ui/surface/component.rb`, `app/components/rbrun/ui/surface/component.html.erb`
- Test: `test/components/rbrun/surface_test.rb`
- Modify: `test/components/rbrun/ui_primitives_test.rb`

**Interfaces:**
- Produces: `component("surface", title:, back:, close:, description:, preset: :card, inset: :padded, elevation: :none, body_id:, footer_id:, css:)` with slots `actions` / `fixed_areas` (many) / `body` / `footer` / `side_panel`. Root `flex min-h-0 min-w-0 flex-auto flex-col` + preset/elevation chrome; header `flex-shrink-0`; body `min-h-0 flex-1 overflow-y-auto` + inset; footer `flex-shrink-0`.

- [ ] **Step 1: Write the failing test**

Create `test/components/rbrun/surface_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class SurfaceTest < ViewComponent::TestCase
    def render_surface(**kwargs, &blk)
      with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::Surface::Component.new(**kwargs), &blk)
      end
    end

    test "root is a heightless flex column with the preset chrome" do
      html = render_surface(preset: :dialog).to_html
      assert_match "flex-auto", html
      assert_match "min-h-0", html
      assert_match "flex-col", html
      assert_match "rounded-xl", html      # :dialog chrome
      refute_match "h-full", html          # never imposes its own height
    end

    test "header renders title, back, description, close and actions; body scrolls" do
      html = render_surface(title: "T", back: "/x", description: "D", close: true) do |s|
        s.with_actions { "ACT" }
        s.with_body { "BODY" }
      end.to_html
      assert_match "<h2", html
      assert_match "T", html
      assert_match "D", html
      assert_match "arrow-left", html                       # back icon path/name
      assert_match %(data-action="overlay#close"), html     # close button
      assert_match "ACT", html
      # body is the single scroll region
      assert_match "overflow-y-auto", html
      assert_match "BODY", html
    end

    test "no header content -> no header bar" do
      html = render_surface { |s| s.with_body { "B" } }.to_html
      refute_match "<h2", html
      refute_match "<header", html
    end

    test "footer + fixed areas + region ids render" do
      html = render_surface(body_id: "drawer_body", footer_id: "drawer_actions") do |s|
        s.with_fixed_area { "TABS" }
        s.with_body { "B" }
        s.with_footer { "FOOT" }
      end.to_html
      assert_match "TABS", html
      assert_match %(id="drawer_body"), html
      assert_match %(id="drawer_actions"), html
      assert_match "FOOT", html
    end

    test "insets: centered wraps a max-w column; padded pads the body" do
      centered = render_surface(inset: :centered) { |s| s.with_body { "B" } }.to_html
      assert_match "max-w-3xl", centered
      padded = render_surface(inset: :padded) { |s| s.with_body { "B" } }.to_html
      assert_match "p-6", padded
    end

    test "elevation adds a shadow" do
      assert_match "shadow-xl", render_surface(elevation: :lg) { |s| s.with_body { "B" } }.to_html
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/components/rbrun/surface_test.rb`
Expected: FAIL — `uninitialized constant Rbrun::Ui::Surface`.

- [ ] **Step 3: Implement the component class**

Create `app/components/rbrun/ui/surface/component.rb`:

```ruby
module Rbrun
  module Ui
    module Surface
      # The one titled, scrollable surface: header → fixed strips → body → footer (→ side panel). Every
      # panel in the app (main page, dialog, drawer, confirm, inline card) composes this; only chrome
      # (preset) / inset / elevation differ. It imposes NO height of its own — as a min-h-0 flex child of
      # a height-bearing flex-column container (the <dialog>/drawer/<main>) the body scrolls the space
      # left after header/footer; with no constraint it grows and nothing scrolls. (Replaces page_header:
      # the header is rendered inline here, nowhere else.)
      class Component < Rbrun::ApplicationViewComponent
        renders_one  :actions
        renders_many :fixed_areas
        renders_one  :body
        renders_one  :footer
        renders_one  :side_panel

        INSET = { padded: "p-6", centered: nil, flush: nil }.freeze # centered wraps an inner column (ERB)

        def initialize(title: nil, back: nil, close: false, description: nil,
                       preset: :card, inset: :padded, elevation: :none,
                       body_id: nil, footer_id: nil, css: nil)
          @title = title
          @back = back
          @close = close
          @description = description
          @preset = preset
          @inset = inset
          @elevation = elevation
          @body_id = body_id
          @footer_id = footer_id
          @css = css
        end

        attr_reader :title, :back, :close, :description, :inset, :body_id, :footer_id

        style do
          base { "flex min-h-0 min-w-0 flex-auto flex-col" }
          variants do
            preset do
              card   { "rounded-lg border bg-white" }
              dialog { "rounded-xl border bg-white" }
              drawer { "rounded-none border-l bg-white" }
              bare   { "" }
            end
            elevation do
              none {}
              sm { "shadow-sm" }
              md { "shadow-md" }
              lg { "shadow-xl" }
            end
          end
        end

        def root_class = cn(style(preset: @preset, elevation: @elevation), @css)

        # scroll region + padding; :centered pads via an inner column (ERB) so the column scrolls.
        def body_class = class_names("min-h-0 flex-1 overflow-y-auto", INSET[@inset])

        def header? = title.present? || back.present? || close || description.present? || actions?
      end
    end
  end
end
```

- [ ] **Step 4: Implement the template**

Create `app/components/rbrun/ui/surface/component.html.erb`:

```erb
<%= tag.div class: root_class do %>
  <% if header? %>
    <header class="flex min-h-16 flex-shrink-0 items-center justify-between gap-4 border-b border-slate-200 px-6 py-3">
      <div class="flex min-w-0 items-center gap-3">
        <% if back.present? %>
          <%= link_to back, "aria-label": "Back",
                class: "flex size-8 shrink-0 items-center justify-center rounded-md text-slate-500 hover:bg-slate-100 hover:text-slate-700" do %>
            <%= lucide_icon("arrow-left", class: "size-4") %>
          <% end %>
        <% end %>
        <% if title.present? || description.present? %>
          <div class="min-w-0">
            <% if title.present? %>
              <h2 class="truncate text-xl font-semibold tracking-tight text-slate-800"><%= title %></h2>
            <% end %>
            <% if description.present? %>
              <p class="mt-0.5 truncate text-sm text-slate-500"><%= description %></p>
            <% end %>
          </div>
        <% end %>
      </div>
      <% if actions? || close %>
        <div class="flex flex-shrink-0 items-center gap-2">
          <%= actions if actions? %>
          <% if close %>
            <button type="button" data-action="overlay#close" aria-label="Close"
                    class="flex size-8 items-center justify-center rounded-md text-slate-400 hover:bg-slate-100 hover:text-slate-600">
              <%= lucide_icon("x", class: "size-5") %>
            </button>
          <% end %>
        </div>
      <% end %>
    </header>
  <% end %>

  <% fixed_areas.each do |area| %>
    <div class="flex-shrink-0 border-b border-slate-200"><%= area %></div>
  <% end %>

  <div<%= body_id ? " id=\"#{body_id}\"".html_safe : "" %> class="<%= body_class %>">
    <% if inset == :centered %>
      <div class="mx-auto w-full max-w-3xl px-6 py-8"><%= body %></div>
    <% else %>
      <%= body %>
    <% end %>
  </div>

  <% if footer? %>
    <footer<%= footer_id ? " id=\"#{footer_id}\"".html_safe : "" %>
            class="flex flex-shrink-0 items-center justify-end gap-2 border-t border-slate-200 px-6 py-4">
      <%= footer %>
    </footer>
  <% end %>

  <% if side_panel? %>
    <%# Reserved for parity (unused today): a second surface sharing this border. %>
    <%= side_panel %>
  <% end %>
<% end %>
```

- [ ] **Step 5: Run the focused test**

Run: `bin/rails test test/components/rbrun/surface_test.rb`
Expected: PASS. (If `id=` interpolation trips HTML-safety, prefer `tag.div(body_wrapper, id: body_id, class: body_class)` in a helper — but the `.html_safe` attribute snippet above renders the id only when present.)

- [ ] **Step 6: Add to the primitives smoke test**

In `test/components/rbrun/ui_primitives_test.rb`, after the `Ui::Skeleton` line, add:

```ruby
        surface = Ui::Surface::Component.new(title: "S", preset: :dialog)
        surface.with_body { "B" }
        assert_match "rounded-xl", render_inline(surface).to_html
```

- [ ] **Step 7: Run smoke + lint + commit**

Run: `bin/rails test test/components/rbrun/ui_primitives_test.rb && bin/rubocop app/components/rbrun/ui/surface test/components/rbrun/surface_test.rb`
Expected: PASS, no offenses.

```bash
git add app/components/rbrun/ui/surface test/components/rbrun/surface_test.rb test/components/rbrun/ui_primitives_test.rb
git commit -m "feat(ui): Surface — the one titled scrollable panel primitive (header/body/footer, natural scroll)"
```

---

### Task 2: Dialog shell bare + `dialog_frame` → surface

**Files:**
- Modify: `app/components/rbrun/ui/dialog/component.rb`
- Modify: `app/components/rbrun/ui/dialog_frame/component.rb`, `app/components/rbrun/ui/dialog_frame/component.html.erb`
- Test: `test/controllers/rbrun/repositories_test.rb` (already asserts the modal shell); rely on it + the system test.

**Interfaces:**
- Consumes: `component("surface", …)` (Task 1).
- Produces: `component("dialog_frame", title:, description:){ body }` renders `<turbo-frame id="modal">` → `component("surface", preset: :dialog, elevation: :lg, …)`. The `<dialog>` shell is bare + flex-col with a flex-passthrough `#modal` frame.

- [ ] **Step 1: Run the existing modal test to confirm current green**

Run: `bin/rails test test/controllers/rbrun/repositories_test.rb -n "/dialog shell/"`
Expected: PASS (guards `h2 "Switch repository"` + the lazy frame). This is the regression guard for this task.

- [ ] **Step 2: Make the `<dialog>` shell bare + flex-col with a passthrough frame**

Replace the `CLASSES` array and `call` in `app/components/rbrun/ui/dialog/component.rb`:

```ruby
        # Bare shell: positioning + backdrop + animation + the max-h that constrains scrolling. Chrome
        # (rounded/border/bg/shadow) now lives on the Surface streamed into #modal. flex-col + a
        # flex-passthrough frame carry the height bound down so the surface body scrolls (not the shell).
        CLASSES = %w[
          m-auto flex w-fit min-w-[20rem] max-w-[92vw] max-h-[90dvh] flex-col bg-transparent p-0
          opacity-0 scale-95 transition duration-200 ease-out motion-reduce:transition-none
          data-[open]:opacity-100 data-[open]:scale-100
          backdrop:bg-slate-950/0 backdrop:transition-colors backdrop:duration-200 backdrop:ease-out
          data-[open]:backdrop:bg-slate-950/40
        ].freeze

        def call
          tag.dialog(
            tag.turbo_frame(nil, id: "modal", class: "flex min-h-0 min-w-0 flex-auto flex-col"),
            class: class_names(CLASSES),
            data: { controller: "overlay", action: "cancel->overlay#cancel click->overlay#backdropClose" }
          )
        end
```

- [ ] **Step 3: Delegate `dialog_frame` to surface**

`app/components/rbrun/ui/dialog_frame/component.rb` keeps its `title:`/`description:` initializer (unchanged). Replace `app/components/rbrun/ui/dialog_frame/component.html.erb` with:

```erb
<%# The modal's content: a Surface (dialog chrome) inside the #modal frame. Header = title/description;
    body = the caller's block. Every modal view still renders THROUGH component("dialog_frame", …). %>
<turbo-frame id="modal">
  <%= component("surface", preset: :dialog, elevation: :lg, title: title, description: description) do |s| %>
    <% s.with_body do %><%= content %><% end %>
  <% end %>
</turbo-frame>
```

- [ ] **Step 4: Rebuild + run the modal test + the system test**

Run: `bun run build && bin/rails test test/controllers/rbrun/repositories_test.rb`
Expected: PASS (the `h2 "Switch repository"` now comes from the Surface header; the lazy `#repo_results` frame + input assertions unchanged).

Run: `bin/rails test:system test/system/rbrun/repo_switcher_test.rb`
Expected: PASS — the dialog opens VISIBLE (surface chrome) and the results list scrolls within `max-h-[90dvh]`.

- [ ] **Step 5: Lint + commit**

```bash
bin/rubocop
git add app/components/rbrun/ui/dialog app/components/rbrun/ui/dialog_frame app/assets/builds/rbrun/rbrun.css
git commit -m "refactor(ui): dialog shell goes bare; dialog_frame renders through Surface"
```

---

### Task 3: Drawer shell bare + `drawer_panel` → surface (ids preserved)

**Files:**
- Modify: `app/components/rbrun/ui/drawer/component.rb`, `app/components/rbrun/ui/drawer_panel/component.rb`
- Test: `test/components/rbrun/ui_primitives_test.rb` (asserts drawer family markers).

**Interfaces:**
- Produces: `component("drawer_panel", title:, padded:){ actions; body }` renders `<turbo-frame id="drawer">` → `component("surface", preset: :drawer, elevation: :lg, close: true, body_id: "drawer_body", footer_id: "drawer_actions", …)`. Drawer `<dialog>` bare + flex-col.

- [ ] **Step 1: Add a drawer_panel assertion to the smoke test**

In `test/components/rbrun/ui_primitives_test.rb`, replace the `DrawerPanel` assertion line with one that pins the preserved broadcast ids:

```ruby
        dp = Ui::DrawerPanel::Component.new(title: "T")
        dp.with_actions { "SAVE" }
        dp_html = render_inline(dp).to_html
        assert_match %(id="drawer_body"), dp_html
        assert_match %(id="drawer_actions"), dp_html
        assert_match "SAVE", dp_html
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/components/rbrun/ui_primitives_test.rb`
Expected: FAIL — current DrawerPanel renders `#drawer_body`/`#drawer_actions` already, BUT confirm it still passes; if the current markup already has those ids this step is a no-op guard. (If it passes, proceed — the guard protects the migration.)

- [ ] **Step 3: Make the drawer `<dialog>` shell bare + flex-col**

Replace `CLASSES`/`call` in `app/components/rbrun/ui/drawer/component.rb`:

```ruby
        # Bare right-anchored shell: fixed position + slide animation + backdrop + h-dvh (the height
        # bound). Chrome (rounded-none/border-l/bg/shadow) now lives on the :drawer Surface.
        CLASSES = %w[
          fixed inset-y-0 right-0 left-auto m-0 flex h-dvh w-full max-w-[760px] flex-col bg-transparent p-0
          translate-x-full transition-transform duration-300 ease-[cubic-bezier(0.2,0,0,1)] motion-reduce:transition-none
          data-[open]:translate-x-0
          backdrop:bg-slate-950/0 backdrop:transition-colors backdrop:duration-300 backdrop:ease-out
          data-[open]:backdrop:bg-slate-950/40
        ].freeze

        def call
          tag.dialog(
            tag.turbo_frame(nil, id: "drawer", class: "flex min-h-0 min-w-0 flex-auto flex-col"),
            class: class_names(CLASSES),
            data: { controller: "overlay", action: "cancel->overlay#cancel click->overlay#backdropClose" }
          )
        end
```

(Preserve the drawer's existing animation/backdrop values from the current file if they differ — copy the exact translate/duration tokens the current `Ui::Drawer` uses, only ADDING `flex flex-col bg-transparent` and REMOVING `rounded-none border-l bg-white shadow-xl`.)

- [ ] **Step 4: Delegate `drawer_panel` to surface**

Replace the `erb_template` in `app/components/rbrun/ui/drawer_panel/component.rb` so it renders through Surface, keeping `title:`/`padded:`/`renders_one :actions` and the `drawer_body`/`drawer_actions` ids:

```ruby
        erb_template <<~ERB
          <%= turbo_frame_tag "drawer" do %>
            <%= component("surface", preset: :drawer, elevation: :lg, title: title, close: true,
                          inset: (padded ? :padded : :flush),
                          body_id: "drawer_body", footer_id: "drawer_actions") do |s| %>
              <% s.with_body do %><%= content %><% end %>
              <% if actions? %><% s.with_footer do %><%= actions %><% end %><% end %>
            <% end %>
          <% end %>
        ERB
```

Keep the `initialize(title: nil, padded: true)` + `renders_one :actions` + the `BODY_ID`/`ACTIONS_ID` constants (now consumed as the surface `body_id`/`footer_id`) in the `.rb`.

- [ ] **Step 5: Build + test + lint + commit**

Run: `bun run build && bin/rails test test/components/rbrun/ui_primitives_test.rb && bin/rubocop`
Expected: PASS, no offenses.

```bash
git add app/components/rbrun/ui/drawer app/components/rbrun/ui/drawer_panel app/assets/builds/rbrun/rbrun.css
git commit -m "refactor(ui): drawer shell goes bare; drawer_panel renders through Surface (ids preserved)"
```

---

### Task 4: `confirm_dialog` inner → surface

**Files:**
- Modify: `app/components/rbrun/ui/confirm_dialog/component.rb`, `app/components/rbrun/ui/confirm_dialog/component.html.erb`
- Test: `test/components/rbrun/ui_primitives_test.rb` (asserts `confirm-dialog` + `data-confirm-accept`).

**Interfaces:** the `<dialog id="confirm-dialog">` shell (driven by `turbo_confirm.js`) goes bare + flex-col; its inner message + buttons render through a Surface (no header, a footer of buttons). The `data-confirm-message` / `data-confirm-accept` / `data-confirm-cancel` hooks are preserved verbatim.

- [ ] **Step 1: Confirm the smoke guard is green now**

Run: `bin/rails test test/components/rbrun/ui_primitives_test.rb -n "/every primitive/"`
Expected: PASS (asserts `confirm-dialog` + `data-confirm-accept` — the migration must keep both).

- [ ] **Step 2: Bare the confirm shell + render its inner via surface**

`app/components/rbrun/ui/confirm_dialog/component.rb`: keep the singleton `<dialog id="confirm-dialog">` but change `CLASSES` to the bare centered shell (drop `rounded-xl border bg-white shadow-xl`, add `flex flex-col bg-transparent`, keep `w-full max-w-sm` + the `data-[open]`/backdrop tokens it already has). Replace `component.html.erb` with:

```erb
<dialog id="confirm-dialog" class="<%= classes %>">
  <%= component("surface", preset: :dialog, elevation: :lg) do |s| %>
    <% s.with_body do %>
      <p class="text-sm text-slate-700" data-confirm-message></p>
    <% end %>
    <% s.with_footer do %>
      <%= component("button", variant: :outline, size: :sm, data: { confirm_cancel: "" }) do %>Cancel<% end %>
      <%= component("button", variant: :primary, size: :sm, data: { confirm_accept: "" }) do %>Confirm<% end %>
    <% end %>
  <% end %>
</dialog>
```

Keep the `classes` method; only its class string changes (bare shell). If the shell has no `flex flex-col`, add it so the surface fills.

- [ ] **Step 3: Build + test + lint + commit**

Run: `bun run build && bin/rails test test/components/rbrun/ui_primitives_test.rb && bin/rubocop`
Expected: PASS (still asserts `confirm-dialog` + `data-confirm-accept`; `data-confirm-message` present).

```bash
git add app/components/rbrun/ui/confirm_dialog app/assets/builds/rbrun/rbrun.css
git commit -m "refactor(ui): confirm dialog renders its message+actions through Surface"
```

---

### Task 5: `page` → surface; delete Page + PageHeader; `<main>` flex-col; migrate the 3 views

**Files:**
- Modify: `app/views/layouts/rbrun/application.html.erb` (`<main>`), `app/views/rbrun/sessions/index.html.erb`, `app/views/rbrun/sessions/show.html.erb`, `app/views/rbrun/skills/index.html.erb`
- Delete: `app/components/rbrun/page/component.rb`, `app/components/rbrun/page/component.html.erb`, `app/components/rbrun/page_header/component.rb`, `app/components/rbrun/page_header/component.html.erb`
- Test: `test/controllers/rbrun/sessions_flow_test.rb` (asserts the sidebar + that pages render).

**Interfaces:** the three views switch from `preset("page", …)` to `component("surface", …)`; `<main>` becomes a flex column so the page surface (`flex-auto`) fills it and its body scrolls.

- [ ] **Step 1: Run the flow test to confirm current green**

Run: `bin/rails test test/controllers/rbrun/sessions_flow_test.rb`
Expected: PASS. Regression guard: it asserts `/rbrun/c` and `/rbrun/c/:id` render (`#conversation_…`, `#composer`) + the sidebar regions.

- [ ] **Step 2: Make `<main>` a flex column**

In `app/views/layouts/rbrun/application.html.erb`, change the `<main>` element to a flex column so the surface fills it:

```erb
    <main class="flex w-full h-full min-h-0 flex-shrink flex-col p-4 pl-1 overflow-hidden"><%= yield %></main>
```

- [ ] **Step 3: Migrate `sessions/index.html.erb`**

Replace its `preset("page", …)` wrapper with Surface (centered, actions + body):

```erb
<%= component("surface", title: "Conversations", inset: :centered) do |s| %>
  <% s.with_actions do %>
    <%= button_to "New conversation", rbrun.sessions_path, method: :post,
          class: "rounded-md bg-default-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-default-500 cursor-pointer" %>
  <% end %>
  <% s.with_body do %>
    <div class="flex flex-col gap-2">
      <% @sessions.each do |session| %>
        <%= link_to rbrun.session_path(session),
              class: "rounded-lg border border-slate-200 p-4 transition-colors hover:border-default-300 hover:bg-slate-50" do %>
          <p class="font-medium text-slate-800"><%= session.display_title %></p>
          <p class="text-xs text-slate-400"><%= session.status %> · <%= session.created_at.strftime("%d/%m/%Y") %></p>
        <% end %>
      <% end %>
      <% if @sessions.empty? %>
        <p class="text-sm text-slate-400">No conversations yet.</p>
      <% end %>
    </div>
  <% end %>
<% end %>
```

- [ ] **Step 4: Migrate `sessions/show.html.erb`** (bleed → `inset: :flush`; the conversation self-scrolls at `h-full`):

```erb
<%# The conversation owns its full-height layout (scrolling timeline + pinned composer). A flush surface
    body gives it h-full; it self-scrolls, so the surface body never overflows. No header. %>
<%= component("surface", inset: :flush) do |s| %>
  <% s.with_body do %>
    <%= render(Rbrun::Sessions::Default::Component.new(session: @session)) %>
  <% end %>
<% end %>
```

- [ ] **Step 5: Migrate `skills/index.html.erb`** — change only the wrapper line from `preset("page", title: "Skills", variant: :centered) do |p|` / `p.with_body` to `component("surface", title: "Skills", inset: :centered) do |s|` / `s.with_body` (body content unchanged).

- [ ] **Step 6: Delete Page + PageHeader**

```bash
git rm app/components/rbrun/page/component.rb app/components/rbrun/page/component.html.erb \
       app/components/rbrun/page_header/component.rb app/components/rbrun/page_header/component.html.erb
```

- [ ] **Step 7: Build + run the flow test + full suite**

Run: `bun run build && bin/rails test test/controllers/rbrun/sessions_flow_test.rb`
Expected: PASS (pages render via Surface; `#conversation_…`/`#composer` present; sidebar unchanged). If any assertion referenced page-specific markup, update it to the Surface equivalent.

- [ ] **Step 8: Lint + commit**

```bash
bin/rubocop
git add app/views/layouts/rbrun/application.html.erb app/views/rbrun/sessions app/views/rbrun/skills app/components/rbrun/page app/components/rbrun/page_header app/assets/builds/rbrun/rbrun.css
git commit -m "refactor(ui): pages render through Surface; delete Page + PageHeader; main is flex-col"
```

---

### Task 6: `card` → surface

**Files:**
- Modify: `app/components/rbrun/ui/card/component.rb`, `app/views/rbrun/auth/sessions/new.html.erb`
- Test: `test/components/rbrun/ui_primitives_test.rb` (asserts card renders a title).

**Interfaces:** `component("card", title:, subtitle:){ body }` becomes a thin wrapper → `component("surface", preset: :card, elevation: :md, title:, description: subtitle){ with_body }`, preserving its one consumer's API.

- [ ] **Step 1: Rewrite Card as a Surface wrapper**

Replace `app/components/rbrun/ui/card/component.rb`:

```ruby
module Rbrun
  module Ui
    module Card
      # A titled inline surface — a thin wrapper over Ui::Surface (preset :card). Kept as its own name
      # for the ergonomic component("card", title:, subtitle:) call; all structure lives in Surface.
      class Component < Rbrun::ApplicationViewComponent
        option :title, optional: true
        option :subtitle, optional: true
        option :css, optional: true

        def call
          render(Rbrun::Ui::Surface::Component.new(
            preset: :card, elevation: :md, title: title, description: subtitle, css: css
          )) { |s| s.with_body { content } }
        end
      end
    end
  end
end
```

- [ ] **Step 2: Confirm the consumer + smoke still assert a title**

`app/views/rbrun/auth/sessions/new.html.erb` uses `component("card", title: "Sign in") do … end` — no change needed (API preserved). The smoke test asserts `render_inline(Ui::Card::Component.new(title: "Card")) → "Card"`; keep it.

- [ ] **Step 3: Build + test + lint + commit**

Run: `bun run build && bin/rails test test/components/rbrun/ui_primitives_test.rb`
Expected: PASS (card renders "Card" via the Surface header).

```bash
bin/rubocop
git add app/components/rbrun/ui/card app/views/rbrun/auth/sessions/new.html.erb app/assets/builds/rbrun/rbrun.css
git commit -m "refactor(ui): card is a thin Surface wrapper"
```

---

### Task 7: Full verification + bundle

**Files:** `app/assets/builds/rbrun/rbrun.{css,js}` (final rebuild).

- [ ] **Step 1: Final build**

Run: `bun run build`
Expected: re-emits both bundles; Tailwind picks up every new Surface/shell class.

- [ ] **Step 2: Full unit/integration/component suite**

Run: `bin/rails test`
Expected: all green (surface + skeleton + list_item + repositories + sessions_flow + primitives smoke, etc.).

- [ ] **Step 3: System suite**

Run: `bin/rails test:system`
Expected: PASS — the repo switcher dialog opens visible via the Surface, results scroll within `max-h`, pick works.

- [ ] **Step 4: Lint + commit the bundle**

Run: `bin/rubocop`
Expected: no offenses.

```bash
git add app/assets/builds/rbrun/rbrun.css app/assets/builds/rbrun/rbrun.js
git commit -m "chore(ui): rebuild bundle for the Surface primitive"
```

---

## Self-Review

**Spec coverage:** §2 primitive → T1; §3 shells bare (dialog/drawer/main flex-col) → T2/T3/T5; §4 migrations page→T5, dialog_frame→T2, drawer_panel→T3, confirm→T4, card→T6; §5 bundle+tests → each task + T7; §1 scroll contract → T1 (root `flex-auto min-h-0`, body `min-h-0 flex-1 overflow-y-auto`) + the flex-passthrough frames in T2/T3 + `<main>` flex-col in T5. ✓

**Placeholder scan:** No TBD/TODO. Every step shows the exact class strings / code. The drawer shell step notes "copy the exact translate/duration tokens the current file uses" — that's a precise instruction to read one value, not a placeholder. ✓

**Type consistency:** `component("surface", title:, back:, close:, description:, preset:, inset:, elevation:, body_id:, footer_id:, css:)` + slots `actions/fixed_areas/body/footer/side_panel` are defined in T1 and consumed identically in T2 (dialog), T3 (drawer, with `body_id: "drawer_body"`/`footer_id: "drawer_actions"`), T4 (confirm), T5 (`inset: :centered|:flush`), T6 (card, `description: subtitle`). `preset` values `:card/:dialog/:drawer/:bare` and `inset` `:padded/:centered/:flush` match the spec table throughout. ✓

**Working-at-every-commit:** each shell goes bare only in the task that migrates its frame to the chrome-bearing surface (T2 dialog, T3 drawer, T4 confirm), so no commit leaves an unchromed panel. ✓
