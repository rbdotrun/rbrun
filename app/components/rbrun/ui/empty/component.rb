module Rbrun
  module Ui
    module Empty
      # An empty-state placeholder: dashed border, min-height, centered. `title` + optional `subtitle`,
      # and an optional `cta` slot (compose a `component("button", …)` into it). Use wherever a list,
      # table, or section has no rows yet. Dumb by design — it renders what it's handed, nothing more.
      class Component < Rbrun::ApplicationViewComponent
        renders_one :cta

        def initialize(title: nil, subtitle: nil)
          @title = title
          @subtitle = subtitle
        end

        attr_reader :title, :subtitle

        erb_template <<~ERB
          <div class="flex min-h-48 items-center justify-center rounded-xl border border-dashed border-slate-300 px-6 py-12">
            <div class="flex flex-col items-center gap-1.5 text-center">
              <% if title.present? %><p class="text-sm font-medium text-slate-700"><%= title %></p><% end %>
              <% if subtitle.present? %><p class="max-w-md text-sm text-slate-400"><%= subtitle %></p><% end %>
              <% if cta? %><div class="mt-3"><%= cta %></div><% end %>
            </div>
          </div>
        ERB
      end
    end
  end
end
