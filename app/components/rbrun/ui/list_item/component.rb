module Rbrun
  module Ui
    module ListItem
      # A reusable two-line list row: a leading avatar spanning both rows, a title, and a muted
      # subtitle. Renders <a role="menuitem" data-menu-target="item"> so it drops into a role="menu"
      # container and inherits the Menu controller's roving-tabindex keyboard nav (or a <div> when no
      # href). `active` → aria-current + a trailing check, mirroring Ui::Menu's Link.
      class Component < Rbrun::ApplicationViewComponent
        BASE     = "group/li flex items-center gap-2.5 rounded-md px-2.5 py-1.5 focus:outline-none".freeze
        INACTIVE = "hover:bg-slate-100 focus:bg-slate-100".freeze
        ACTIVE   = "bg-slate-100".freeze
        AVATAR   = "flex size-9 shrink-0 items-center justify-center self-center rounded bg-slate-200 text-xs font-semibold text-slate-600".freeze
        TITLE    = "truncate text-sm font-medium text-slate-900".freeze
        SUBTITLE = "truncate text-xs text-slate-500".freeze
        CHECK    = "size-4 shrink-0 self-center text-slate-500".freeze

        def initialize(title:, subtitle: nil, avatar: nil, href: nil, active: false, **attrs)
          @title = title
          @subtitle = subtitle
          @avatar = avatar
          @href = href
          @active = active
          @attrs = attrs
        end

        def call
          data  = { menu_target: "item" }.merge(@attrs.delete(:data) || {})
          klass = class_names(BASE, @active ? ACTIVE : INACTIVE, @attrs.delete(:class))
          body  = safe_join([ leading, text_stack, trailing ].compact)

          if @href
            link_to(@href, role: "menuitem", tabindex: "-1", data:,
                           aria: { current: (@active ? "true" : nil) }, class: klass, **@attrs) { body }
          else
            tag.div(body, role: "menuitem", tabindex: "-1", data: data, class: klass, **@attrs)
          end
        end

        private

        def leading
          tag.span(@avatar, class: AVATAR) if @avatar.present?
        end

        def text_stack
          tag.span(class: "flex min-w-0 flex-1 flex-col") do
            safe_join([
              tag.span(@title, class: TITLE),
              (tag.span(@subtitle, class: SUBTITLE) if @subtitle.present?)
            ].compact)
          end
        end

        def trailing
          lucide_icon("check", class: CHECK) if @active
        end
      end
    end
  end
end
