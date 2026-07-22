module Rbrun
  module Ui
    module Tabs
      # A horizontal tab bar of links. Each tab: {label:, href:, key:, active:}. The active tab carries
      # aria-current="page". A tab may carry `count:` — rendered as a badge (capped at "99+"). Faithfully
      # ported from ../insitix (Primitives::Tabs).
      class Component < Rbrun::ApplicationViewComponent
        MAX_BADGE = 99

        def initialize(tabs:, label: "Tabs")
          @tabs = tabs
          @label = label
        end

        def badge_count(count)
          count.to_i > MAX_BADGE ? "#{MAX_BADGE}+" : count.to_i.to_s
        end
      end
    end
  end
end
