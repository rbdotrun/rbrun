module Rbrun
  module Ui
    module Tooltip
      class Component < Rbrun::ApplicationViewComponent
        option :text
        option :css, optional: true

        def classes = cn("relative inline-flex group", css)

        erb_template <<~ERB
          <span class="<%= classes %>">
            <%= content %>
            <span class="pointer-events-none absolute -top-8 left-1/2 -translate-x-1/2 whitespace-nowrap rounded bg-gray-900 px-2 py-1 text-xs text-white opacity-0 group-hover:opacity-100 transition"><%= text %></span>
          </span>
        ERB
      end
    end
  end
end
