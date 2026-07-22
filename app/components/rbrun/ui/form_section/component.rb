module Rbrun
  module Ui
    module FormSection
      # A titled section of a form: a heading (title + rule) with an optional description, over a grid
      # of its content. `columns` is the lg-breakpoint column count. Faithfully ported from ../insitix.
      class Component < Rbrun::ApplicationViewComponent
        GRID = {
          1 => "grid grid-cols-1 gap-x-6 gap-y-4",
          2 => "grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-4",
          3 => "grid grid-cols-2 lg:grid-cols-3 gap-x-6 gap-y-4"
        }.freeze

        def initialize(title: nil, description: nil, columns: 1, separator: nil)
          @title = title
          @description = description
          @columns = columns
          @separator = separator.nil? ? title.present? : separator
        end

        def call
          tag.div(class: "flex flex-col gap-4",
                  role: (@title.present? ? "group" : nil), "aria-label": @title.presence) do
            safe_join([ header, tag.div(content, class: GRID.fetch(@columns, GRID[2])) ].compact)
          end
        end

        private

          def header
            return unless @title.present? || @description.present?

            tag.div(class: "flex flex-col gap-1") { safe_join([ title_row, description_row ].compact) }
          end

          def title_row
            return unless @title.present?

            tag.div(class: "flex items-center gap-3") do
              safe_join([
                tag.span(@title, class: "shrink-0 text-base font-semibold text-slate-800"),
                (tag.span(class: "h-px flex-1 bg-slate-200") if @separator)
              ].compact)
            end
          end

          def description_row
            tag.p(@description, class: "text-sm text-slate-500") if @description.present?
          end
      end
    end
  end
end
