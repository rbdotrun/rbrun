module Rbrun
  module Ui
    module Table
      # A CSS-grid "table" (not a <table>). Pass `columns:` (header labels) and append `with_row { … }`
      # per row. `template:` overrides equal-width tracks with an explicit grid-template-columns string.
      # `flush:` drops the card chrome; `headless:` drops the header (for a stacked infinite-scroll
      # batch). Faithfully ported from ../insitix (Primitives::Table).
      class Component < Rbrun::ApplicationViewComponent
        renders_many :rows

        def initialize(columns:, template: nil, flush: false, headless: false, **attrs)
          @columns = columns
          @template = template
          @flush = flush
          @headless = headless
          @attrs = attrs
        end

        def wrapper_classes = @flush ? "" : "overflow-hidden rounded-xl border border-slate-200 bg-white"
        def headless? = @headless
        def rows_classes = class_names("divide-y divide-slate-200", ("border-t border-slate-200" if @headless))

        def grid_style
          tracks = @template.presence || "repeat(#{@columns.size}, minmax(0, 1fr))"
          "grid-template-columns: #{tracks}"
        end
      end
    end
  end
end
