module Rbrun
  module Ui
    module NavItem
      # A single sidebar navigation row: leading lucide icon + label, with a real active state.
      # Active is auto-detected from the current request path
      # (exact match via current_page?) unless an explicit active: is passed.
      #
      #   <%= component("nav_item", label: "Conversations", href: sessions_path, icon: "messages-square") %>
      class Component < Rbrun::ApplicationViewComponent
        # px-3 puts the icon's center on the collapsed rail's axis (12 + 12 + 8 = 32).
        BASE = "group flex items-center gap-2.5 rounded-md px-3 py-1.5 text-sm font-medium " \
               "transition-colors focus-visible:outline-none focus-visible:ring-2 " \
               "focus-visible:ring-default-500 focus-visible:ring-offset-1".freeze

        # In the collapsed rail the label stays in the flow and only fades (fast out; back in slightly
        # delayed, while the width reopens) — the icon never moves, the shrinking rail clips the text.
        LABEL = "whitespace-nowrap transition-[opacity,visibility] duration-300 delay-75 " \
                "group-data-[collapsed]/sidebar:opacity-0 group-data-[collapsed]/sidebar:invisible " \
                "group-data-[collapsed]/sidebar:duration-150 group-data-[collapsed]/sidebar:delay-0".freeze

        INACTIVE = "text-slate-600 hover:bg-slate-100 hover:text-slate-900".freeze
        ACTIVE   = "bg-default-50 text-default-700".freeze

        ICON_BASE     = "size-4 shrink-0".freeze
        ICON_INACTIVE = "text-slate-400 group-hover:text-slate-600".freeze
        ICON_ACTIVE   = "text-default-600".freeze

        def initialize(label:, href:, icon: nil, active: nil, **attrs)
          @label = label
          @href = href
          @icon = icon
          @active = active
          @attrs = attrs
        end

        def call
          link_to(@href, class: class_names(BASE, active? ? ACTIVE : INACTIVE, @attrs.delete(:class)),
                         title: @label, aria: { current: ("page" if active?) }, **@attrs) do
            safe_join([ icon_tag, tag.span(@label, class: LABEL) ].compact)
          end
        end

        private

          def active?
            return @active unless @active.nil?

            @href.present? && @href != "#" && helpers.current_page?(@href)
          rescue StandardError
            false
          end

          def icon_tag
            return if @icon.blank?

            lucide_icon(@icon, class: class_names(ICON_BASE, active? ? ICON_ACTIVE : ICON_INACTIVE))
          end
      end
    end
  end
end
