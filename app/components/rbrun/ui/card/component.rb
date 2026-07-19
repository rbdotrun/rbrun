module Rbrun
  module Ui
    module Card
      class Component < Rbrun::ApplicationViewComponent
        option :title, optional: true
        option :subtitle, optional: true
        option :css, optional: true

        def classes = cn("rounded-lg shadow-md ring-1 ring-black/5 bg-white p-6", css)

        erb_template <<~ERB
          <%= content_tag(:div, class: classes) do %>
            <% if title || subtitle %>
              <div class="flex flex-col mb-3">
                <% if title %><h3 class="text-xl font-semibold"><%= title %></h3><% end %>
                <% if subtitle %><p class="text-sm text-gray-500"><%= subtitle %></p><% end %>
              </div>
            <% end %>
            <%= content %>
          <% end %>
        ERB
      end
    end
  end
end
