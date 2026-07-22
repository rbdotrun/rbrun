module Rbrun
  module Page
    # The one page shell. A white card holding: a header (optional back + title + actions), any number of
    # stacked static fixed_areas (tabs, filter toolbars — never scroll), and a body. Ported from ../insitix
    # (Custom::Page). The layout only FRAMES this card (outer p-4 pl-1); every page renders exactly one
    # `preset("page", ...)` into <main>.
    #
    # `variant` declares how the body relates to scroll (the layout no longer owns it):
    #   :document (default) — body scrolls its natural-height content
    #   :bleed              — body fills and manages its OWN scroll (the conversation, a table)
    #   :centered           — body scrolls a centered max-w-3xl column (forms, detail)
    #
    #   <%= preset("page", title: "Conversations", variant: :centered) do |p| %>
    #     <% p.with_actions { ... } %>
    #     <% p.with_fixed_area { ... tabs ... } %>
    #     <% p.with_body { ... } %>
    #   <% end %>
    #
    # `side_panel` puts a second surface BESIDE the page, inside the same card (one border, one seam);
    # it brings its own header and owns its own scroll. Unused in rbrun today — kept for parity.
    class Component < Rbrun::ApplicationViewComponent
      renders_one :actions
      renders_many :fixed_areas
      renders_one :body
      renders_one :side_panel

      def initialize(title: nil, variant: :document, back: nil)
        @title = title
        @variant = variant
        @back = back
      end

      attr_reader :title, :back

      def header?   = title.present? || back.present? || actions?
      def bleed?    = @variant == :bleed
      def centered? = @variant == :centered
    end
  end
end
