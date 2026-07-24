module Rbrun
  module Ui
    module Menu
      # A keyboard-reachable list of menu actions. Standalone, or composed inside a Ui::Dropdown to
      # form the classic dropdown menu. Items are added in
      # insertion order via plain methods so mixed header/link/separator sequences keep their order:
      #
      #   <%= component("menu") do |m| %>
      #     <% m.current "rbdotrun/rbrun", avatar: "RB" %>
      #     <% m.link "rbdotrun/scratch", href: "#", avatar: "RB" %>
      #     <% m.separator %>
      #   <% end %>
      #
      # Each link renders role="menuitem"; the Dropdown controller focuses the first on open, and the
      # Menu controller wires roving-tabindex keyboard nav.
      class Component < Rbrun::ApplicationViewComponent
        # ── Item: link (<a role="menuitem">) ──────────────────────────────────
        class Link < Rbrun::ApplicationViewComponent
          BASE     = "group/mi flex items-center gap-2.5 rounded-md px-2.5 py-1.5 text-sm focus:outline-none".freeze
          INACTIVE = "text-slate-700 hover:bg-slate-100 hover:text-slate-900 focus:bg-slate-100 focus:text-slate-900".freeze
          ACTIVE   = "bg-slate-100 font-medium text-slate-900".freeze
          DISABLED = "text-slate-300 cursor-not-allowed".freeze
          ICON     = "size-4 shrink-0 text-slate-400".freeze
          CHECK    = "size-4 shrink-0 text-slate-500".freeze
          AVATAR   = "flex size-5 shrink-0 items-center justify-center rounded bg-slate-200 text-[10px] font-semibold text-slate-600".freeze

          def initialize(label:, href:, icon: nil, avatar: nil, active: false, disabled: false, **attrs)
            @label = label
            @href = href
            @icon = icon
            @avatar = avatar
            @active = active
            @disabled = disabled
            @attrs = attrs
          end

          def call
            return disabled_item if @disabled

            data = { menu_target: "item" }.merge(@attrs.delete(:data) || {})
            link_to(@href, role: "menuitem", tabindex: "-1", data:,
                           aria: { current: (@active ? "true" : nil) },
                           class: class_names(BASE, @active ? ACTIVE : INACTIVE, @attrs.delete(:class)), **@attrs) do
              safe_join([ leading, tag.span(@label, class: "flex-1 truncate"), trailing ].compact)
            end
          end

          private

            def disabled_item
              tag.span(role: "menuitem", tabindex: "-1", "aria-disabled": "true",
                       data: { menu_target: "item" }, class: class_names(BASE, DISABLED)) do
                safe_join([ leading, tag.span(@label, class: "flex-1 truncate") ].compact)
              end
            end

            def leading
              if @avatar.present?
                tag.span(@avatar, class: AVATAR)
              elsif @icon.present?
                lucide_icon(@icon, class: ICON)
              end
            end

            def trailing
              lucide_icon("check", class: CHECK) if @active
            end
        end

        # ── Item: current (avatar + bold name, non-interactive) ───────────────
        class Current < Rbrun::ApplicationViewComponent
          AVATAR = "flex size-5 shrink-0 items-center justify-center rounded bg-slate-900 text-[10px] font-semibold text-white".freeze

          def initialize(label:, avatar: nil)
            @label = label
            @avatar = avatar
          end

          def call
            tag.div(class: "flex items-center gap-2.5 px-2.5 py-1.5") do
              safe_join([
                (tag.span(@avatar, class: AVATAR) if @avatar.present?),
                tag.span(@label, class: "flex-1 truncate text-sm font-semibold text-slate-900")
              ].compact)
            end
          end
        end

        # ── Item: header (small group label) ──────────────────────────────────
        class Header < Rbrun::ApplicationViewComponent
          def initialize(text:)
            @text = text
          end

          def call
            tag.div(@text, class: "px-2.5 pt-1.5 pb-0.5 text-xs font-medium uppercase tracking-wide text-slate-400")
          end
        end

        # ── Item: separator (<hr>) ────────────────────────────────────────────
        class Separator < Rbrun::ApplicationViewComponent
          def call
            tag.hr(role: "separator", class: "my-1 border-t")
          end
        end

        renders_many :items, types: {
          link: Link,
          current: Current,
          header: Header,
          separator: Separator
        }

        def link(label, href:, icon: nil, avatar: nil, active: false, disabled: false, **attrs)
          with_item_link(label:, href:, icon:, avatar:, active:, disabled:, **attrs)
          nil
        end

        def current(label, avatar: nil)
          with_item_current(label:, avatar:)
          nil
        end

        def header(text)
          with_item_header(text:)
          nil
        end

        def separator
          with_item_separator
          nil
        end

        def call
          content # evaluate the block so m.link / m.header / m.separator populate the slots
          tag.div(role: "menu", class: "min-w-56 p-1",
                  data: { controller: "menu", action: "keydown->menu#navigate" }) do
            safe_join(items)
          end
        end
      end
    end
  end
end
