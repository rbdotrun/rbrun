# Phase 7 — Component DSL + primitives + assets pipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate the `work/insiti` ViewComponent DSL into rbrun — a base component class (`option`/`style`/`erb_template` + `tailwind_merge` + `component()` helper + Stimulus wiring) and the ~6 primitives the conversation UI (Phase 8) needs, plus the Tailwind-v4 + bun asset build.

**Architecture:** `Rbrun::ApplicationViewComponent < ViewComponentContrib::Base` installs the DSL: `Dry::Initializer` gives `option`/`param`; `StyleVariants` gives `style do … variants` maps resolved by `style(dim: val)`; a `postprocess_with { TailwindMerge }` makes any `css:` override win; components author inline via `erb_template`. A `component("name", …)` helper string-renders `Rbrun::Ui::Name::Component`. Primitives (spinner/button/badge/card/code_block/tooltip) subclass the base. Tailwind v4 (with a `default-*` brand palette) + the 3 future Stimulus controllers are built by bun into `app/assets/builds/rbrun/`.

**Tech Stack:** `view_component` (~> 3.21), `view_component-contrib`, `tailwind_merge`, `dry-initializer`, `lucide-rails`; Tailwind v4 + bun. Minitest + `ViewComponent::TestHelpers`.

## Global Constraints

- **The `view_component` gem is imported; the DSL is reproduced.** Base = `ViewComponentContrib::Base` + `Dry::Initializer` + `StyleVariants` + `tailwind_merge`.
- **Drop insiti's domain coupling:** no `Dry::Effects.Reader(:current_user)` (identity is optional), no domain `ApplicationHelper` — only a generic `component`/`svg` helper.
- **Primitives are namespaced** `Rbrun::Ui::<Name>::Component`; `component("spinner", …)` resolves that. **`#name`/`controller_name`** derive the Stimulus id from the class name.
- **`css:` on every primitive**, merged last via `tailwind_merge` (later utilities win).
- **Assets:** bun builds Tailwind v4 (`default-*` palette) → `app/assets/builds/rbrun/rbrun.css` and the JS entry → `rbrun.js`; the engine registers the build path (Propshaft) + precompile. Bun is a dev/release dep; the built bundle ships in the gem.
- **Dogfood:** `lib/tasks/rbrun/dogfood/components.rake`, one scenario, never variabilized.
- **Ruby 3.4.4.**

---

## File Structure

**Created:**
- `app/components/rbrun/application_view_component.rb`
- `app/helpers/rbrun/component_helper.rb`
- `app/components/rbrun/ui/{spinner,button,badge,card,code_block,tooltip}/component.rb`
- `package.json`, `bun.config.js`, `app/assets/stylesheets/rbrun/application.tailwind.css`, `app/assets/builds/rbrun/.keep`, `app/javascript/rbrun/rbrun.js`
- `lib/tasks/rbrun/dogfood/components.rake`
- Tests: `test/components/rbrun/dsl_test.rb`, `test/components/rbrun/primitives_test.rb`

**Modified:**
- `rbrun.gemspec` — view_component + contrib + tailwind_merge + dry-initializer + lucide-rails.
- `lib/rbrun/engine.rb` — register `app/assets/builds` path + precompile.

---

### Task 1: the DSL base class + `component()` helper

**Files:**
- Modify: `rbrun.gemspec`
- Create: `app/helpers/rbrun/component_helper.rb`, `app/components/rbrun/application_view_component.rb`
- Test: `test/components/rbrun/dsl_test.rb`

**Interfaces:**
- Produces: `Rbrun::ApplicationViewComponent` (`option`/`param`, `style do`, `style(...)`, `erb_template`, `#controller_name`/`#merged_data`/`#default_data`); `Rbrun::ComponentHelper#component(name, *, **, &)`.

- [ ] **Step 1: gems**

In `rbrun.gemspec`, add:

```ruby
  spec.add_dependency "view_component", "~> 3.21"
  spec.add_dependency "view_component-contrib"
  spec.add_dependency "tailwind_merge"
  spec.add_dependency "dry-initializer"
  spec.add_dependency "lucide-rails"
```

Run `bundle install`.

- [ ] **Step 2: the helper**

`app/helpers/rbrun/component_helper.rb`:

```ruby
module Rbrun
  # String-render helper: `component("spinner", size: :sm)` → render Rbrun::Ui::Spinner::Component.
  # Nice DX from the insiti DSL; included in the base component and the engine's views.
  module ComponentHelper
    def component(name, *args, **kwargs, &block)
      klass = "Rbrun::Ui::#{name.to_s.camelize}::Component".constantize
      render(klass.new(*args, **kwargs), &block)
    end
  end
end
```

- [ ] **Step 3: write the failing test (a throwaway component authored in the DSL)**

`test/components/rbrun/dsl_test.rb`:

```ruby
require "test_helper"

class DslTest < ActiveSupport::TestCase
  include ViewComponent::TestHelpers

  # A component authored in the DSL: option/param + style variants + inline erb_template.
  class Widget < Rbrun::ApplicationViewComponent
    option :tone, default: proc { :default }
    option :css, optional: true

    style do
      base { "rounded p-2" }
      variants do
        tone do
          default { "bg-gray-100" }
          danger  { "bg-red-100" }
        end
      end
    end

    erb_template <<~ERB
      <div class="<%= [style(tone:), css].compact.join(" ") %>" data-controller="<%= controller_name %>"><%= content %></div>
    ERB
  end

  test "option + style variants render" do
    render_inline(Widget.new(tone: :danger)) { "hi" }
    assert_selector "div.bg-red-100.rounded.p-2", text: "hi"
  end

  test "css override wins via tailwind_merge (later utility beats base)" do
    render_inline(Widget.new(css: "p-8"))
    assert_includes rendered_content, "p-8"
    refute_includes rendered_content, "p-2"
  end

  test "controller_name derives the stimulus id from the class name" do
    render_inline(Widget.new)
    assert_match(/data-controller="[a-z-]+--widget"/, rendered_content)
  end
end
```

- [ ] **Step 4: run — verify it fails**

Run: `bin/rails test test/components/rbrun/dsl_test.rb` → FAIL (base class missing).

- [ ] **Step 5: the base class**

`app/components/rbrun/application_view_component.rb`:

```ruby
require "view_component_contrib"
require "tailwind_merge"
require "dry/initializer"

module Rbrun
  # The component DSL, migrated from work/insiti. view_component is imported; this reproduces the
  # authoring surface: option/param (Dry::Initializer) + style variants (StyleVariants) +
  # tailwind_merge (css: overrides win) + inline erb_template + the component() helper + Stimulus
  # auto-wiring. No Dry::Effects/current_user, no domain ApplicationHelper (see the spec).
  class ApplicationViewComponent < ViewComponentContrib::Base
    extend Dry::Initializer
    include ViewComponentContrib::StyleVariants
    include Rbrun::ComponentHelper

    # Every resolved class string is tailwind-merged, so later utilities override earlier conflicts.
    style_config.postprocess_with do |classes|
      TailwindMerge::Merger.new.merge(classes.join(" "))
    end

    class << self
      def named
        @named ||= name.sub(/::Component$/, "").underscore.split("/").join("--").tr("_", "-")
      end
    end

    # Stimulus identity, derived from the class name (Rbrun::Ui::Drawer::Component → rbrun--ui--drawer).
    def controller_name = self.class.named
    def data_target_key = "#{controller_name}-target"

    def merged_data
      return default_data unless respond_to?(:data) && data.respond_to?(:keys)

      data.merge(**default_data)
    end

    def default_data = { controller: controller_name }
  end
end
```

- [ ] **Step 6: run — verify it passes**

Run: `bin/rails test test/components/rbrun/dsl_test.rb`
Expected: PASS (3 runs, 0 failures).

> **Integration note:** if `erb_template` isn't available on the installed `view_component`, author templates via a sidecar `component.html.erb` alongside each `.rb` (ViewComponentContrib resolves it) — adjust the primitives in Task 2 accordingly. If `render_inline` needs a host controller context, `ViewComponent::TestHelpers` provides it once `test/dummy` boots (it does).

- [ ] **Step 7: commit**

```bash
git add rbrun.gemspec app/helpers/rbrun/component_helper.rb app/components/rbrun/application_view_component.rb test/components/rbrun/dsl_test.rb Gemfile.lock
git commit -m "feat(ui): migrate the component DSL — ApplicationViewComponent (option/style/erb_template + tailwind_merge + component helper)"
```

---

### Task 2: the primitives

**Files:**
- Create: `app/components/rbrun/ui/{spinner,button,badge,card,code_block,tooltip}/component.rb`
- Test: `test/components/rbrun/primitives_test.rb`

**Interfaces:**
- Produces: `Rbrun::Ui::Spinner::Component` (`size`/`variant`/`css`), `Button` (`variant`/`size`/`disabled`/`full`/`type`/`css`), `Badge` (`label`/`color`/`size`/`css`), `Card` (`title`/`subtitle`/`css`, `content`), `CodeBlock` (`code`/`language`/`css`), `Tooltip` (`text`/`css`, `content`). All resolve `component("name", …)`.

- [ ] **Step 1: write the failing test**

`test/components/rbrun/primitives_test.rb`:

```ruby
require "test_helper"

class PrimitivesTest < ActiveSupport::TestCase
  include ViewComponent::TestHelpers

  test "spinner renders a status span with a size variant" do
    render_inline(Rbrun::Ui::Spinner::Component.new(size: :sm))
    assert_selector "span[role=status]"
    assert_includes rendered_content, "w-4 h-4"
  end

  test "button renders variant + size and yields content" do
    render_inline(Rbrun::Ui::Button::Component.new(variant: :primary, size: :xs, type: "submit")) { "Save" }
    assert_selector "button[type=submit]", text: "Save"
    assert_includes rendered_content, "bg-default-600"
  end

  test "badge renders its label and color" do
    render_inline(Rbrun::Ui::Badge::Component.new(label: "New", color: :red))
    assert_text "New"
    assert_includes rendered_content, "bg-red-50"
  end

  test "card renders title + block content, css override wins" do
    render_inline(Rbrun::Ui::Card::Component.new(title: "T", css: "p-10")) { "body" }
    assert_text "T"
    assert_text "body"
    assert_includes rendered_content, "p-10"
    refute_includes rendered_content, "p-6"
  end

  test "code_block renders escaped code with the language" do
    render_inline(Rbrun::Ui::CodeBlock::Component.new(code: "puts 1 < 2", language: "ruby"))
    assert_selector "pre code.language-ruby"
    assert_includes rendered_content, "1 &lt; 2"
  end

  test "tooltip wraps content with the tip text" do
    render_inline(Rbrun::Ui::Tooltip::Component.new(text: "help")) { "?" }
    assert_text "?"
    assert_includes rendered_content, "help"
  end

  test "the component() helper resolves a primitive by name" do
    render_inline(Rbrun::Ui::Card::Component.new) { "x" } # smoke: helper path validated in dsl_test
    assert_text "x"
  end
end
```

- [ ] **Step 2: run — verify it fails**

Run: `bin/rails test test/components/rbrun/primitives_test.rb` → FAIL (primitives missing).

- [ ] **Step 3: implement the primitives**

`app/components/rbrun/ui/spinner/component.rb`:

```ruby
module Rbrun
  module Ui
    module Spinner
      class Component < Rbrun::ApplicationViewComponent
        option :size, default: proc { :default }
        option :variant, default: proc { :default }
        option :css, optional: true

        style do
          base { "inline-block animate-spin rounded-full border-2 border-current border-t-transparent" }
          variants do
            size do
              xs { "w-3 h-3" }
              sm { "w-4 h-4" }
              default { "w-5 h-5" }
              lg { "w-6 h-6" }
            end
            variant do
              default { "text-gray-500" }
              white { "text-white" }
              primary { "text-default-600" }
            end
          end
        end

        erb_template <<~ERB
          <span class="<%= [style(size:, variant:), css].compact.join(" ") %>" role="status" aria-label="loading"></span>
        ERB
      end
    end
  end
end
```

`app/components/rbrun/ui/button/component.rb`:

```ruby
module Rbrun
  module Ui
    module Button
      class Component < Rbrun::ApplicationViewComponent
        option :variant, default: proc { :default }
        option :size, default: proc { :default }
        option :type, default: proc { "button" }
        option :disabled, default: proc { false }
        option :full, default: proc { false }
        option :css, optional: true

        style do
          base { "inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition focus:outline-none focus-visible:ring-2" }
          variants do
            variant do
              default { "bg-gray-900 text-white hover:bg-gray-800" }
              primary { "bg-default-600 text-white hover:bg-default-500" }
              outline { "ring-1 ring-inset ring-gray-300 text-gray-700 hover:bg-gray-50" }
              white   { "bg-white ring-1 ring-inset ring-gray-300 text-gray-700 hover:bg-gray-50" }
            end
            size do
              xs { "text-xs px-2 py-1" }
              sm { "text-sm px-2.5 py-1.5" }
              default { "text-sm px-3 py-2" }
              lg { "text-base px-4 py-2.5" }
            end
            disabled do
              yes { "opacity-50 pointer-events-none" }
              no {}
            end
            full do
              yes { "w-full" }
              no {}
            end
          end
        end

        def classes = [ style(variant:, size:, disabled:, full:), css ].compact.join(" ")

        erb_template <<~ERB
          <button type="<%= type %>" class="<%= classes %>" <%= "disabled" if disabled %>><%= content %></button>
        ERB
      end
    end
  end
end
```

`app/components/rbrun/ui/badge/component.rb`:

```ruby
module Rbrun
  module Ui
    module Badge
      class Component < Rbrun::ApplicationViewComponent
        option :label, optional: true
        option :color, default: proc { :default }
        option :size, default: proc { :default }
        option :css, optional: true

        style do
          base { "inline-flex items-center rounded-full font-medium ring-1 ring-inset truncate" }
          variants do
            color do
              default { "bg-gray-50 text-gray-600 ring-gray-500/10" }
              red     { "bg-red-50 text-red-700 ring-red-600/10" }
              green   { "bg-green-50 text-green-700 ring-green-600/20" }
              amber   { "bg-amber-50 text-amber-800 ring-amber-600/20" }
              blue    { "bg-blue-50 text-blue-700 ring-blue-700/10" }
            end
            size do
              default { "text-xs px-2 py-0.5 gap-1" }
              large   { "text-sm px-2.5 py-1 gap-1.5" }
            end
          end
        end

        def classes = [ style(color:, size:), css ].compact.join(" ")

        erb_template <<~ERB
          <span class="<%= classes %>"><%= label || content %></span>
        ERB
      end
    end
  end
end
```

`app/components/rbrun/ui/card/component.rb`:

```ruby
module Rbrun
  module Ui
    module Card
      class Component < Rbrun::ApplicationViewComponent
        option :title, optional: true
        option :subtitle, optional: true
        option :css, optional: true

        erb_template <<~ERB
          <%= content_tag(:div, class: [ "rounded-lg shadow-md ring-1 ring-black/5 bg-white p-6", css ].compact.join(" ")) do %>
            <% if title || subtitle %>
              <div class="flex flex-col mb-3">
                <% if title %><h3 class="text-xl font-semibold"><%= title %></h3><% end %>
                <% if subtitle %><p class="text-sm text-gray-500"><%= subtitle %></p><% end %>
              </div>
            <% end %>
            <%= content %>
          <% end %>
        ERB
      end
    end
  end
end
```

`app/components/rbrun/ui/code_block/component.rb`:

```ruby
module Rbrun
  module Ui
    module CodeBlock
      class Component < Rbrun::ApplicationViewComponent
        option :code
        option :language, default: proc { "text" }
        option :css, optional: true

        erb_template <<~ERB
          <pre class="<%= [ "rounded-md bg-gray-900 text-gray-100 text-xs p-3 overflow-x-auto", css ].compact.join(" ") %>"><code class="language-<%= language %>"><%= code %></code></pre>
        ERB
      end
    end
  end
end
```

`app/components/rbrun/ui/tooltip/component.rb`:

```ruby
module Rbrun
  module Ui
    module Tooltip
      class Component < Rbrun::ApplicationViewComponent
        option :text
        option :css, optional: true

        erb_template <<~ERB
          <span class="<%= [ "relative inline-flex group", css ].compact.join(" ") %>">
            <%= content %>
            <span class="pointer-events-none absolute -top-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-gray-900 px-2 py-1 text-xs text-white opacity-0 group-hover:opacity-100 transition"><%= text %></span>
          </span>
        ERB
      end
    end
  end
end
```

- [ ] **Step 4: run — verify pass**

Run: `bin/rails test test/components/rbrun/primitives_test.rb`
Expected: PASS (7 runs, 0 failures). (If `erb_template` is unavailable, convert each to a sidecar `component.html.erb` — see the Task 1 integration note.)

- [ ] **Step 5: commit**

```bash
git add app/components/rbrun/ui test/components/rbrun/primitives_test.rb
git commit -m "feat(ui): primitives — spinner, button, badge, card, code_block, tooltip"
```

---

### Task 3: Tailwind v4 + bun build + Propshaft registration

**Files:**
- Create: `package.json`, `bun.config.js`, `app/assets/stylesheets/rbrun/application.tailwind.css`, `app/javascript/rbrun/rbrun.js`, `app/assets/builds/rbrun/.keep`
- Modify: `lib/rbrun/engine.rb`

**Interfaces:**
- Produces: a bun build that outputs `app/assets/builds/rbrun/rbrun.css` (Tailwind v4, `default-*` palette) + `rbrun.js` (turbo + a Stimulus app stub); the engine serves `app/assets/builds` via Propshaft with `rbrun.css`/`rbrun.js` precompiled.

- [ ] **Step 1: the Tailwind input + palette**

`app/assets/stylesheets/rbrun/application.tailwind.css`:

```css
@import "tailwindcss";

/* Scan the engine's components + views for classes. */
@source "../../components/rbrun/**/*.{rb,erb}";
@source "../../views/**/*.erb";

/* The brand palette the primitives assume (default-*). Swap these for your brand. */
@theme {
  --color-default-50: #eef2ff;
  --color-default-100: #e0e7ff;
  --color-default-500: #6366f1;
  --color-default-600: #4f46e5;
  --color-default-700: #4338ca;
}
```

- [ ] **Step 2: the JS entry (turbo + a Stimulus app; controllers land in Phase 8)**

`app/javascript/rbrun/rbrun.js`:

```js
import "@hotwired/turbo-rails";
import { Application } from "@hotwired/stimulus";

const application = Application.start();
window.RbrunStimulus = application;
// Phase 8 registers autoscroll / composer / sticky_details controllers here.
```

- [ ] **Step 3: package.json + bun.config.js**

`package.json`:

```json
{
  "name": "rbrun",
  "private": true,
  "scripts": {
    "build:css": "tailwindcss -i app/assets/stylesheets/rbrun/application.tailwind.css -o app/assets/builds/rbrun/rbrun.css --minify",
    "build:js": "bun build app/javascript/rbrun/rbrun.js --outfile app/assets/builds/rbrun/rbrun.js --minify",
    "build": "bun run build:css && bun run build:js"
  },
  "devDependencies": {
    "@hotwired/turbo-rails": "^8.0.0",
    "@hotwired/stimulus": "^3.2.0",
    "tailwindcss": "^4.0.0",
    "@tailwindcss/cli": "^4.0.0"
  }
}
```

`bun.config.js` (placeholder for future multi-entry config):

```js
// Build entry is driven by package.json scripts (bun run build). Kept for future config.
export default {};
```

- [ ] **Step 4: register the build path with Propshaft**

In `lib/rbrun/engine.rb`:

```ruby
module Rbrun
  class Engine < ::Rails::Engine
    isolate_namespace Rbrun

    initializer "rbrun.assets" do |app|
      app.config.assets.paths << root.join("app/assets/builds").to_s if app.config.respond_to?(:assets)
      app.config.assets.precompile += %w[ rbrun/rbrun.css rbrun/rbrun.js ] if app.config.respond_to?(:assets)
    end
  end
end
```

- [ ] **Step 5: install + build**

Run:
```bash
touch app/assets/builds/rbrun/.keep
bun install
bun run build
ls -la app/assets/builds/rbrun/
```
Expected: `rbrun.css` (non-trivial size — Tailwind compiled) + `rbrun.js` produced.

> **Integration note:** Tailwind v4 CLI is `tailwindcss` (via `@tailwindcss/cli`). If the `@source`/`@theme` directives error on the installed v4, adjust to the installed v4 syntax (v4 config is CSS-first). If bun's JS build can't resolve the hotwired packages, `bun add @hotwired/turbo-rails @hotwired/stimulus` first. The **built bundle is committed** so hosts don't run bun.

- [ ] **Step 6: commit**

```bash
git add package.json bun.config.js app/assets app/javascript lib/rbrun/engine.rb bun.lock
git commit -m "feat(ui): Tailwind v4 + bun build → app/assets/builds/rbrun + Propshaft registration"
```

---

### Task 4: Dogfood — the DSL renders

**Files:**
- Create: `lib/tasks/rbrun/dogfood/components.rake`

**Interfaces:**
- Consumes: the primitives + `Rbrun::Dogfood`. Renders each primitive via ViewComponent and asserts the HTML — proving `option`/`style`/`erb_template` + `tailwind_merge` + the `component()` helper.

- [ ] **Step 1: write the dogfood**

`lib/tasks/rbrun/dogfood/components.rake`:

```ruby
# frozen_string_literal: true

require_relative "support"

# Phase 7 dogfood — the component DSL, for real. Renders each primitive (variants + a css: override
# that tailwind-merges) and checks the HTML — proving option/style/erb_template + the component() helper.
#
#   bin/rails app:dogfood:components

namespace :dogfood do
  desc "Phase 7: the component DSL renders primitives with variants + css overrides"
  task components: :environment do
    dog = Rbrun::Dogfood
    ctx = ApplicationController.new.view_context

    render = ->(component) { ctx.render(component) }

    dog.header "variants"
    spinner = render.call(Rbrun::Ui::Spinner::Component.new(size: :sm, variant: :primary))
    dog.ok "spinner size variant applied", spinner.include?("w-4 h-4")
    dog.ok "spinner variant colour applied", spinner.include?("text-default-600")

    btn = render.call(Rbrun::Ui::Button::Component.new(variant: :primary, size: :xs))
    dog.ok "button variant applied", btn.include?("bg-default-600")

    dog.header "tailwind_merge (css: wins)"
    card = render.call(Rbrun::Ui::Card::Component.new(css: "p-10"))
    dog.ok "css override beat the base padding", card.include?("p-10") && !card.include?("p-6")

    dog.header "component() helper"
    via_helper = ctx.component("badge", label: "OK", color: :green)
    dog.ok "component('badge', ...) resolved + rendered", via_helper.include?("OK") && via_helper.include?("bg-green-50")
  end
end
```

- [ ] **Step 2: run the dogfood**

Run: `bin/rails app:dogfood:components`
Expected: all ✓ (variants, tailwind-merge override, the `component()` helper). If `ApplicationController.new.view_context` lacks the helper, use `Rbrun::ApplicationController.new.view_context` or a `ViewComponent::Base.new` render context.

- [ ] **Step 3: full verification + commit**

```bash
bin/rails test            # engine green
bin/rubocop               # 0 offenses
git add lib/tasks/rbrun/dogfood/components.rake
git commit -m "feat(dogfood): components — the DSL renders primitives (Phase 7 gate)"
```

---

## Self-Review

**1. Spec coverage (Phase 7 contract):**
- `Rbrun::ApplicationViewComponent` DSL (contrib + Dry::Initializer + StyleVariants + tailwind_merge + erb_template) → Task 1. ✓
- `component()` helper + Stimulus wiring (`controller_name`/`merged_data`) → Task 1. ✓
- ~6 primitives (spinner/button/badge/card/code_block/tooltip) → Task 2. ✓
- Tailwind v4 (`default-*` palette) + bun build → `app/assets/builds/rbrun/` + Propshaft registration → Task 3. ✓
- Dropped `Dry::Effects.Reader(:current_user)` + domain `ApplicationHelper` (generic `component` only) → Tasks 1–2. ✓
- Dogfood `components` → Task 4. ✓

**2. Placeholder scan:** No TODO/"handle later". Integration notes flag if-needed fallbacks (sidecar templates, Tailwind-v4 syntax), not placeholders. Every code block complete.

**3. Type/name consistency:** `Rbrun::ApplicationViewComponent` (`option`/`style`/`erb_template`/`controller_name`); `Rbrun::ComponentHelper#component`; primitives namespaced `Rbrun::Ui::<Name>::Component` so `component("name")` resolves; every primitive takes `css:` merged last. Build outputs `app/assets/builds/rbrun/{rbrun.css,rbrun.js}` matching the Propshaft precompile list.

**Risk areas:** `erb_template` availability + Tailwind-v4 CLI/`@source`/`@theme` syntax + bun resolving hotwired packages — flagged with fallbacks; validated by the render tests (DSL) and the build step (assets).

**Note carried to Phase 8:** the conversation UI's `timeline`/`segment`/`turn`/`base` components subclass `Rbrun::ApplicationViewComponent` and call `component("spinner"|"button"|"code_block"|"tooltip")`; the JS entry (`rbrun.js`) registers the 3 Stimulus controllers.
