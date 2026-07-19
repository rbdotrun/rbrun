module Rbrun
  module Ui
    module Badge
      class Component < Rbrun::ApplicationViewComponent
        option :label, optional: true
        option :color, default: proc { :default }
        option :size, default: proc { :default }
        option :css, optional: true

        style do
          base { "inline-flex items-center rounded-full font-medium ring-1 ring-inset truncate" }
          variants do
            color do
              default { "bg-gray-50 text-gray-600 ring-gray-500/10" }
              red     { "bg-red-50 text-red-700 ring-red-600/10" }
              green   { "bg-green-50 text-green-700 ring-green-600/20" }
              amber   { "bg-amber-50 text-amber-800 ring-amber-600/20" }
              blue    { "bg-blue-50 text-blue-700 ring-blue-700/10" }
            end
            size do
              default { "text-xs px-2 py-0.5 gap-1" }
              large   { "text-sm px-2.5 py-1 gap-1.5" }
            end
          end
        end

        def classes = cn(style(color:, size:), css)

        erb_template <<~ERB
          <span class="<%= classes %>"><%= label || content %></span>
        ERB
      end
    end
  end
end
