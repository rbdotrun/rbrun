module Rbrun
  module Ui
    module Table
      # A CSS-grid "table" (not a <table>). ONE way to fill it: a `collection:` rendered through a
      # `row:` partial. Each row partial wraps its cells in `component("table_row", id: dom_id(record),
      # …)`, so every row is a dom_id-keyed element inside a stable container (`id:`). That makes a
      # table streamable BY DEFAULT — a Turbo broadcast can append ONE row or replace ONE row without
      # repainting the table; a "static" table is simply one nothing broadcasts to. No separate mode.
      #
      # `columns:` are header labels. `template:` overrides equal-width tracks (also threaded to each
      # row so its grid lines up with the header). `row_as:` names the record local the partial gets
      # (default :record). `flush:` drops the card chrome; `headless:` drops the header. Faithfully
      # ported from ../insitix (Primitives::Table).
      class Component < Rbrun::ApplicationViewComponent
        # The empty-state, rendered as a `peer-empty` sibling of the rows container: the container is
        # ALWAYS present (so a broadcast can append into it), and this shows only while it has no rows —
        # auto-hiding the instant a row streams in. Compose `component("empty", …)` into it.
        renders_one :empty

        def initialize(columns:, row: nil, collection: [], row_as: :record,
                       id: nil, template: nil, flush: false, headless: false, **attrs)
          @columns = columns
          @row = row
          @collection = collection
          @row_as = row_as
          @id = id
          @template = template
          @flush = flush
          @headless = headless
          @attrs = attrs
        end

        attr_reader :columns, :row, :collection, :row_as, :id

        # flush: the header PINS via `absolute` inside a `relative` wrapper (never scrolls away, unlike
        # `sticky`), and the rows reserve an equal fixed-height gap (`HEADER_H`) so the first row clears
        # it. Non-flush: the header rides in normal flow inside the card.
        HEADER_H = "h-11"

        def headless? = @headless
        def flush? = @flush

        def wrapper_classes
          @flush ? "relative" : "overflow-hidden rounded-xl border border-slate-200 bg-white"
        end

        def header_classes
          base = "grid items-center gap-4 border-b border-slate-200 bg-slate-50 px-6 text-xs font-medium uppercase tracking-wider text-slate-500"
          @flush ? "#{base} absolute inset-x-0 top-0 z-10 #{HEADER_H}" : "#{base} py-3"
        end

        def rows_classes
          base = class_names("divide-y divide-slate-200", ("border-t border-slate-200" if @headless))
          @flush ? "#{base} pt-11" : base
        end

        def grid_template = @template.presence || "repeat(#{@columns.size}, minmax(0, 1fr))"
        def grid_style = "grid-template-columns: #{grid_template}"
      end
    end
  end
end
