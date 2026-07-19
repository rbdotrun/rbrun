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
    ctx = Rbrun::ApplicationController.new.view_context

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
