module Rbrun
  module Ui
    module BulkBar
      # Floating bulk-action bar for a `bulk-select` controller: a clear (X) button, a pluralized count,
      # and a caller-provided `actions` slot. Enters on selection with scale+fade+slide-up, driven by the
      # controller toggling `data-visible`. Faithfully ported from ../insitix (Primitives::BulkBar).
      class Component < Rbrun::ApplicationViewComponent
        renders_one :actions

        BAR = "pointer-events-none absolute inset-x-0 bottom-4 z-20 mx-auto flex w-fit items-center gap-1.5 " \
              "rounded-lg border border-slate-200 bg-white py-1.5 pl-1.5 pr-2 shadow-lg " \
              "translate-y-2 scale-95 opacity-0 transition-[transform,opacity] duration-150 ease-out motion-reduce:transition-none " \
              "data-[visible]:pointer-events-auto data-[visible]:translate-y-0 data-[visible]:scale-100 data-[visible]:opacity-100"

        def initialize(singular:, plural:)
          @singular = singular
          @plural = plural
        end

        erb_template <<~ERB
          <div data-bulk-select-target="bar" class="<%= BAR %>">
            <button type="button" data-action="bulk-select#clear" aria-label="Clear selection"
                    class="rounded p-1.5 text-slate-400 transition-colors hover:bg-slate-100 hover:text-slate-700">
              <%= lucide_icon("x", class: "size-4") %>
            </button>
            <span class="h-5 w-px bg-slate-200"></span>
            <span class="px-1 text-sm text-slate-700">
              <span data-bulk-select-target="count" class="font-semibold text-slate-900 tabular-nums">0</span>
              <span data-bulk-select-target="label" data-singular="<%= @singular %>" data-plural="<%= @plural %>"><%= @singular %></span>
            </span>
            <span class="h-5 w-px bg-slate-200"></span>
            <div class="flex items-center gap-1"><%= actions %></div>
          </div>
        ERB
      end
    end
  end
end
