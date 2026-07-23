module Rbrun
  module Ui
    module TableRow
      # ONE grid row of a Ui::Table — the same markup whether the table loops it or a Turbo broadcast
      # renders it standalone. That identity is the whole point: give the row a stable `id`
      # (`dom_id(record)`) and it becomes append/replace-addressable, so a live list table streams a
      # single row instead of repainting the whole table. `template` MUST match the table's grid tracks
      # so a streamed row lines up with the header. Compose the cells as the block content.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(template:, id: nil)
          @template = template
          @id = id
        end

        attr_reader :template, :id

        erb_template <<~ERB
          <div id="<%= id %>" class="grid items-center gap-4 px-6 py-4 transition-colors hover:bg-slate-50" style="grid-template-columns: <%= template %>">
            <%= content %>
          </div>
        ERB
      end
    end
  end
end
