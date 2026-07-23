# Surface Primitive — Design

> Feature spec. Extracts the ONE invariant titled/scrollable surface that `page`, `dialog_frame`,
> `drawer_panel`, `confirm_dialog`, and `card` each re-implement today, into a single primitive
> (`Rbrun::Ui::Surface`) that all of them compose. One spec → one plan → branch → TDD → PR.

**Goal:** A single primitive — `component("surface", …)` — that owns the invariant way rbrun renders a
titled, scrollable panel: **header → fixed strips → body → footer (→ side panel)**. Every surface in
the app (main page, dialog, drawer, confirm, inline card) renders THROUGH it; only chrome (radius,
border, elevation, body inset) differs, selected by props/presets. `page_header` folds in as the
surface's nested header. `page` (the folder component) is retired.

**One-line contract:** the surface **never imposes its own height**. In a height-constrained ancestor
(a dialog's `max-h`, a drawer's `h-dvh`, the page's full-height `<main>`) the **body scrolls** the space
left after header/footer. With no height constraint (an inline card, a short dialog) the surface **grows
to content and nothing scrolls**. Same markup both ways — this is natural flex behaviour, not a mode.

**How it works mechanically (the whole trick):** the surface root is `flex flex-col min-h-0` with **no
height**; the body is `flex-1 min-h-0 overflow-y-auto`. For the body to actually scroll, the surface must
be a **`min-h-0` flex child of a flex-column container that carries the height bound** — the `<dialog>`
becomes `max-h-[90dvh] flex flex-col`, the drawer `h-dvh flex flex-col`, `<main>` a flex column. Then:
constrained container → surface bounded → body scrolls; short content → container is `max-h` (not fixed)
so it shrinks to content → surface grows → `overflow-y-auto` finds no overflow → no scrollbar. A `max-h`
WITHOUT this flex-child chain would clip, not scroll — hence the container change in §3 is required, not
cosmetic.

---

## 1. Why

Today the same structure — **[header: title (+back|+close|+description) + actions] → [fixed strips] →
[one scroll body] → [footer of actions] → [optional side surface]** — is authored five times, with only
cosmetic divergence (header `h-16 text-xl` vs `py-4 text-lg` vs `p-6`; actions in the header seam vs a
footer; radius `rounded-lg`/`rounded-xl`/`rounded-none`; scroll owned internally vs delegated to a
`<dialog>` shell). insitix even bridges two of them at runtime (`Custom::Showable` forwards
title+actions+body to _either_ page _or_ drawer_panel) — proving they're one thing rendered many ways,
but still composing two duplicated implementations. This spec removes the duplication: one primitive,
many presets.

Consumers that exist today (the whole contract to preserve): `page` is used by exactly three views
(`sessions/index` centered + actions + body; `sessions/show` bleed + body; `skills/index` centered +
body); `page`'s `fixed_areas`/`side_panel`/`back` are **unused** (parity-only) and free to redesign.
`card` has one consumer (`auth/sessions/new`). `dialog_frame` is used by the repo-switcher dialog (the
canonical example). `drawer_panel`/`confirm_dialog` are singleton-shell content.

---

## 2. `Rbrun::Ui::Surface` — the primitive

`app/components/rbrun/ui/surface/component.rb` (+ sidecar `component.html.erb`). A `component("surface")`
(flat `Rbrun::Ui::` primitive) so both folder components (`custom`) and other primitives (`component`)
can compose it.

### 2.1 Structure (outer → in)

```
<div surface>  flex min-h-0 min-w-0 flex-col  + [preset chrome] + [elevation]   ← NO fixed height
  ├ Surface::Header   (nested subcomponent; render?-guarded)
  │     ├ left:  optional back <a> (arrow-left) · title <h?> · optional description
  │     ├ right: actions slot
  │     └ optional close ✕ button (data-action="overlay#close") — for dialog/drawer
  ├ fixed_areas   renders_many   each: flex-shrink-0 border-b  (tabs/filter strips)
  ├ body          renders_one    flex-1 min-h-0 overflow-y-auto  + [inset]
  └ footer        renders_one    flex-shrink-0 border-t · items-center justify-end gap-2  (actions row)
  (side_panel)    renders_one    optional split-pane sibling sharing one border
```

**Scroll is automatic (§1 contract).** Header/footer are `flex-shrink-0`; the body is
`flex-1 min-h-0 overflow-y-auto`. `overflow-y-auto` shows a scrollbar only on real overflow, so a
constrained ancestor makes the body scroll (its area = total − header − footer) and an unconstrained one
lets the whole surface grow with no scrollbar. A body whose child manages its own scroll (the
conversation) simply fills the body at `h-full` and never overflows it — no special mode needed.

### 2.2 Props

| prop           | values                                      | effect                                                                    |
| -------------- | ------------------------------------------- | ------------------------------------------------------------------------- |
| `title:`       | string / nil                                | header title                                                              |
| `back:`        | href / nil                                  | header back link (`arrow-left`)                                           |
| `close:`       | bool (default false)                        | header ✕ button, `data-action="overlay#close"` (dialog/drawer)            |
| `description:` | string / nil                                | muted subline under the title                                             |
| `preset:`      | `:card`\* · `:dialog` · `:drawer` · `:bare` | **chrome only** (radius + border)                                         |
| `inset:`       | `:padded`\* · `:centered` · `:flush`        | body box: `p-6` · `mx-auto max-w-3xl px-6 py-8` · none                    |
| `elevation:`   | `:none`\* · `:sm` · `:md` · `:lg`           | shadow (independent of preset)                                            |
| `body_id:`     | string / nil                                | stable id on the body region (drawer broadcast target `drawer_body`)      |
| `footer_id:`   | string / nil                                | stable id on the footer region (drawer broadcast target `drawer_actions`) |
| `css:`         | string / nil                                | tailwind-merge override on the outer element                              |

\* = default. Chrome presets:

| preset    | classes                          | used by                              |
| --------- | -------------------------------- | ------------------------------------ |
| `:card`   | `rounded-lg border bg-white`     | inline card + the main page          |
| `:dialog` | `rounded-xl border bg-white`     | modal content                        |
| `:drawer` | `rounded-none border-l bg-white` | right slide-over (radius/edge tweak) |
| `:bare`   | (none)                           | nested / chromeless                  |

Built with `StyleVariants` (`preset`/`inset`/`elevation` as variants) + `cn(…, css)` so a `css:` override
wins (mirrors `Ui::Button`). Header height stays **declared** (not padding-derived) so a page header
(`text-xl`) and a side-panel header land on the same baseline and the divider doesn't step.

### 2.3 Slots

`renders_one :actions`, `renders_many :fixed_areas`, `renders_one :body`, `renders_one :footer`,
`renders_one :side_panel`. Block-form in ERB (`do <%= body %> end`, not `{ body }`) — the helper forwards
the block to `render`, which captures buffer output (documented caveat carried from Page).

### 2.4 `Surface::Header` (replaces `page_header`)

A nested subcomponent (inner class rendered by the surface template, or a private partial), NOT a
standalone `custom("page_header")`. Params `title:`, `back:`, `close:`, `description:` + the `actions`
content. `render?` = any of title/back/close/description/actions present (no empty bordered bar). This is
the only home for the header markup; `Rbrun::PageHeader` is deleted.

---

## 3. The `<dialog>` shells go bare

The singleton `<dialog>` shells stay (positioning, backdrop, `overlay` controller open/close, and the
**height constraint** that drives body scrolling) but **drop border/radius/bg** and become
**flex-column containers** so the surface (their `min-h-0` flex child) inherits the height bound (§1).

- **Dialog** (`Ui::Dialog`): keep `m-auto w-fit min-w-[20rem] max-w-[92vw] max-h-[90dvh]`, backdrop,
  `data-[open]` animation; **add `flex flex-col`**; **remove `rounded-xl border bg-white shadow-xl`** and
  the shell's own `overflow-y-auto` (→ the `:dialog` surface + its body scroll). The surface body scrolls
  within `max-h-[90dvh]`; short content shrinks the dialog and doesn't scroll.
- **Drawer** (`Ui::Drawer`): keep `fixed inset-y-0 right-0 h-dvh w-full max-w-[760px]`, slide animation,
  backdrop; **add `flex flex-col`** (it already implied a column); **remove `rounded-none border-l
bg-white shadow-xl`** (→ the `:drawer` surface).
- **`<main>` / page:** `<main>` (or a thin wrapper) becomes a flex column and the page surface its
  `flex-1 min-h-0` child, so a full-height page scrolls its body while a short one grows.
- Backdrop-click-to-close is unchanged: the `<dialog>` still wraps the surface, so a click resolving to
  the `<dialog>` element (`event.target === this.element`) still closes.
- Elevation: the floating look (shadow) moves onto the surface via `elevation:` (`:lg` for dialog/drawer).

---

## 4. Migrations (everything)

| today                                                       | becomes                                                                                                                                                                                 |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `custom("page", title:, variant: :centered){actions,body}`  | `component("surface", title:, inset: :centered){ with_actions; with_body }`                                                                                                             |
| `custom("page", variant: :bleed){body}`                     | `component("surface", inset: :flush){ with_body }` (self-scrolling child fills it)                                                                                                      |
| `Rbrun::Page` + `Rbrun::PageHeader`                         | **deleted** (folder components retired)                                                                                                                                                 |
| `component("dialog_frame", title:, description:){body}`     | wrapper: `turbo_frame_tag "modal"` → `component("surface", preset: :dialog, elevation: :lg, title:, description:){ with_body }` — same API                                              |
| `component("drawer_panel", title:, padded:){actions; body}` | wrapper: `turbo_frame_tag "drawer"` → `component("surface", preset: :drawer, elevation: :lg, title:, close: true, inset: padded ? :padded : :flush){ with_footer{actions}; with_body }` |
| `component("confirm_dialog")` inner                         | `component("surface", preset: :dialog, elevation: :lg, inset: :padded){ with_body{msg}; with_footer{buttons} }` (keep `data-confirm-*` hooks + `#confirm-dialog` shell)                 |
| `component("card", title:, subtitle:)`                      | `component("surface", preset: :card, elevation: :md, title:, description:){ with_body{content} }`                                                                                       |

- `dialog_frame` / `drawer_panel` keep their names + ergonomic APIs (thin wrappers over `surface`) so
  callers (incl. `repositories/dialog.html.erb`) are untouched or nearly so. `repositories/dialog.html.erb`
  then flows through `surface` for free — the canonical example.
- **Drawer broadcast targets preserved:** the drawer's body/footer must keep the stable ids
  `drawer_body` / `drawer_actions` so Turbo streams swap a REGION (never the frame — the overlay
  controller derives open/closed from the frame having children). The surface must accept ids on its body
  and footer regions (`body_id:` / `footer_id:` props, nil by default); `drawer_panel` passes them. Same
  discipline the current `DrawerPanel` documents.
- `card`: the one consumer (`auth/sessions/new`) switches; rbrun's divergent `shadow-md`/`text-gray-500`
  card is normalized to the slate surface (`elevation: :md`).
- `Ui::Section` / `Ui::FormSection` are **out of scope** (titled _content sections_, not panels) — left
  as-is; a later pass may reconcile.

---

## 5. Bundle + tests

- **Bundle:** the shells' class changes + the new surface classes require `bun run build` (the corrected
  `@source` from the prior fix already scans `components/rbrun/**`).
- **Component tests:** `test/components/rbrun/surface_test.rb` — header render?-guard (empty → nothing),
  title/back/close/description, `actions`/`footer`/`fixed_areas`/`body` slots, each `preset` chrome class,
  `inset`/`elevation` classes, and the scroll contract (body carries `flex-1 min-h-0 overflow-y-auto`;
  outer carries no fixed height). Add `surface` to `ui_primitives_test.rb`; delete the `page_header`
  path if referenced.
- **Regression:** existing `sessions_flow_test`, `repositories_test`, and the `repo_switcher` system test
  must stay green — page renders, the dialog still opens with a visible, scrollable panel. Update any
  assertion that named `#page-header`/page-specific markup.
- **Dogfood:** unaffected (selectors are `#repo_switcher`/`dialog[open]`/`#repo_results`, not
  surface-internal).

---

## 6. Inherited invariants

- Primitives-first (the CLAUDE.md banner): this IS that work — one primitive, composed everywhere.
- No registry / no self-registration (#1); RubyLLM engine-only (#9) — untouched.
- Tailwind scans `components/rbrun/**` + `views/**` via the corrected `@source`; rebuild the bundle.
