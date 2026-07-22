module Rbrun
  module Ui
    module Pagination
      # Numbered pagination with prev/next and ellipsis gaps. `href` is a proc mapping a page number to a
      # URL (callers keep their own query params). Faithfully ported from ../insitix (Primitives::Pagination).
      class Component < Rbrun::ApplicationViewComponent
        LINK    = "inline-flex h-9 min-w-9 items-center justify-center rounded-md border border-slate-300 px-3 text-sm text-slate-700 hover:bg-slate-50"
        CURRENT = "inline-flex h-9 min-w-9 items-center justify-center rounded-md border border-default-600 bg-default-600 px-3 text-sm font-semibold text-white"
        DISABLED = "inline-flex h-9 min-w-9 items-center justify-center rounded-md border border-slate-200 px-3 text-sm text-slate-300"

        def initialize(page:, total_pages:, href:, window: 1)
          @page = page.to_i
          @total = total_pages.to_i
          @href = href
          @window = window
        end

        def render? = @total > 1

        def call
          tag.nav(class: "flex flex-wrap items-center justify-center gap-1", "aria-label": "Pagination") do
            safe_join([ prev_link, *number_links, next_link ])
          end
        end

        private

          def page_items
            return (1..@total).to_a if @total <= 7

            left  = [ @page - @window, 1 ].max
            right = [ @page + @window, @total ].min
            items = [ 1 ]
            items << :gap if left > 2
            (left..right).each { |p| items << p unless p == 1 || p == @total }
            items << :gap if right < @total - 1
            items << @total
            items
          end

          def number_links
            page_items.map do |item|
              if item == :gap
                tag.span("…", class: "px-2 text-slate-400")
              elsif item == @page
                tag.span(item, class: CURRENT, "aria-current": "page")
              else
                link_to(item, @href.call(item), class: LINK)
              end
            end
          end

          def prev_link
            if @page > 1
              link_to(@href.call(@page - 1), class: LINK, "aria-label": "Previous") { helpers.lucide_icon("chevron-left", class: "size-4") }
            else
              tag.span(class: DISABLED, "aria-hidden": true) { helpers.lucide_icon("chevron-left", class: "size-4") }
            end
          end

          def next_link
            if @page < @total
              link_to(@href.call(@page + 1), class: LINK, "aria-label": "Next") { helpers.lucide_icon("chevron-right", class: "size-4") }
            else
              tag.span(class: DISABLED, "aria-hidden": true) { helpers.lucide_icon("chevron-right", class: "size-4") }
            end
          end
      end
    end
  end
end
