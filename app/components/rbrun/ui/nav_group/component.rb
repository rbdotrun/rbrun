module Rbrun
  module Ui
    module NavGroup
      # A sidebar group heading. Ported from insiti Primitives::NavGroup. The box keeps the same fixed
      # height in both rail states: expanded it shows the label; collapsed the label fades out and a
      # short 1px separator fades in at its place, so the rows below never move.
      #
      #   <%= component("nav_group", label: "Library") %>
      class Component < Rbrun::ApplicationViewComponent
        BASE = "relative px-2.5 pt-3 pb-1 text-xs font-medium uppercase tracking-wide text-slate-400".freeze

        # Same fade rule as NavItem::LABEL: fast out on collapse; back in slightly delayed.
        LABEL = "whitespace-nowrap transition-[opacity,visibility] duration-300 delay-75 " \
                "group-data-[collapsed]/sidebar:opacity-0 group-data-[collapsed]/sidebar:invisible " \
                "group-data-[collapsed]/sidebar:duration-150 group-data-[collapsed]/sidebar:delay-0".freeze

        # The label's stand-in on the rail — inverse phase of LABEL. Only visible collapsed.
        LINE = "absolute inset-x-2.5 bottom-4 h-px bg-border opacity-0 transition-opacity duration-150 " \
               "group-data-[collapsed]/sidebar:opacity-100 group-data-[collapsed]/sidebar:duration-300 " \
               "group-data-[collapsed]/sidebar:delay-75".freeze

        def initialize(label:)
          @label = label
        end

        def call
          tag.div(class: BASE) do
            safe_join([ tag.span(@label, class: LABEL), tag.span("", class: LINE, aria: { hidden: true }) ])
          end
        end
      end
    end
  end
end
