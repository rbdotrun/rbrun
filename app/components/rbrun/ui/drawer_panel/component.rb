module Rbrun
  module Ui
    module DrawerPanel
      # The CONTENT that loads into the app-wide right drawer (Ui::Drawer's <turbo-frame id="drawer">).
      # Every view rendered into the drawer wraps its body in this: the frame + a header (optional title
      # + close) + a scrollable body + an OPTIONAL actions footer. `padded:` is the body inset (false =
      # full-bleed). Faithfully ported from ../insitix (Primitives::DrawerPanel).
      class Component < Rbrun::ApplicationViewComponent
        # Stable broadcast targets: swap a REGION, never the frame (the overlay controller derives
        # open/closed from whether the frame has children — replacing the frame reads as close→reopen).
        BODY_ID    = "drawer_body"
        ACTIONS_ID = "drawer_actions"

        renders_one :actions

        def initialize(title: nil, padded: true)
          @title = title
          @padded = padded
        end

        attr_reader :title, :padded

        erb_template <<~ERB
          <%= helpers.turbo_frame_tag "drawer" do %>
            <div class="flex h-full flex-col">
              <header class="flex flex-shrink-0 items-center justify-between gap-4 border-b border-slate-200 px-6 py-4">
                <% if title.present? %>
                  <h2 class="truncate text-lg font-semibold text-slate-800" title="<%= title %>"><%= title %></h2>
                <% end %>
                <button type="button" data-action="overlay#close" class="ml-auto text-slate-400 hover:text-slate-600" aria-label="Close">
                  <%= lucide_icon("x", class: "size-5") %>
                </button>
              </header>
              <div id="<%= BODY_ID %>" class="min-h-0 flex-1 <%= padded ? "overflow-y-auto p-6" : "overflow-hidden" %>"><%= content %></div>
              <% if actions? %>
                <footer id="<%= ACTIONS_ID %>" class="flex flex-shrink-0 items-center justify-end gap-2 border-t border-slate-200 px-6 py-4"><%= actions %></footer>
              <% end %>
            </div>
          <% end %>
        ERB
      end
    end
  end
end
