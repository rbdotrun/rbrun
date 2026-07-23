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

        # The frame + a :drawer Surface. Same title/close header, a scrollable body (padded ↔ flush),
        # and the OPTIONAL actions footer — all now the Surface's job. The stable BODY_ID/ACTIONS_ID ride
        # onto the surface's body/footer regions so Turbo streams still swap a REGION, never the frame.
        erb_template <<~ERB
          <%= helpers.turbo_frame_tag "drawer" do %>
            <%= component("surface", preset: :drawer, elevation: :lg, title: title, close: true,
                          inset: (padded ? :padded : :flush),
                          body_id: BODY_ID, footer_id: ACTIONS_ID) do |s| %>
              <% s.with_body do %><%= content %><% end %>
              <% if actions? %><% s.with_footer do %><%= actions %><% end %><% end %>
            <% end %>
          <% end %>
        ERB
      end
    end
  end
end
