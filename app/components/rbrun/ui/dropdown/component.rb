module Rbrun
  module Ui
    module Dropdown
      # A trigger + a floating menu panel. Positioning is
      # computed by Floating UI in the `dropdown` Stimulus controller (offset / flip / shift, tracks
      # on scroll+resize); the controller also owns toggle, outside-click dismiss, Escape-to-close,
      # focus return, and focus-first-item on open.
      #
      #   <%= component("dropdown", placement: :top_start, trigger_class: "block w-full") do |d| %>
      #     <% d.with_trigger do %><button type="button">Menu ▾</button><% end %>
      #     <% d.with_menu do |m| %>
      #       <% m.link "Sign out", href: logout_path, icon: "log-out", data: { turbo_method: :delete } %>
      #     <% end %>
      #   <% end %>
      class Component < Rbrun::ApplicationViewComponent
        # First-paint anchor (top-0 left-0 m-0) + Floating UI's required w-max, so the panel is at a
        # known spot before the controller snaps it into position.
        PANEL = "top-0 left-0 m-0 w-max fixed z-50 " \
                "bg-white text-slate-900 border rounded-md shadow-lg focus:outline-none".freeze

        def initialize(placement: :bottom_start, offset: 6, trigger_class: "inline-block", panel_class: nil, **attrs)
          @placement = placement
          @offset = offset
          @trigger_class = trigger_class
          @panel_class = panel_class
          @attrs = attrs
        end

        renders_one :trigger
        renders_one :menu, Rbrun::Ui::Menu::Component
        # Arbitrary panel content (e.g. a search input + a Turbo frame) when the floating panel isn't
        # a plain menu. Positioning/open/close behaviour is identical — only the content differs.
        renders_one :panel

        def floating_placement = @placement.to_s.tr("_", "-")

        erb_template <<~ERB
          <div data-controller="dropdown"
               data-dropdown-placement-value="<%= floating_placement %>"
               data-dropdown-offset-value="<%= @offset %>"
               class="<%= class_names("relative", @attrs.delete(:class)) %>"
               <%= tag.attributes(@attrs) %>>
            <div data-dropdown-target="trigger"
                 data-action="click->dropdown#toggle"
                 aria-haspopup="menu"
                 class="<%= @trigger_class %>">
              <%= trigger %>
            </div>
            <div data-dropdown-target="content"
                 tabindex="-1"
                 hidden
                 aria-hidden="true"
                 class="<%= class_names(PANEL, @panel_class) %>">
              <%= menu %><%= panel %>
            </div>
          </div>
        ERB
      end
    end
  end
end
