module Rbrun
  module Ui
    module Button
      class Component < Rbrun::ApplicationViewComponent
        option :variant, default: proc { :default }
        option :size, default: proc { :default }
        option :type, default: proc { "button" }
        option :disabled, default: proc { false }
        option :full, default: proc { false }
        option :css, optional: true

        style do
          base { "inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition focus:outline-none focus-visible:ring-2" }
          variants do
            variant do
              default { "bg-gray-900 text-white hover:bg-gray-800" }
              primary { "bg-default-600 text-white hover:bg-default-500" }
              outline { "ring-1 ring-inset ring-gray-300 text-gray-700 hover:bg-gray-50" }
              white   { "bg-white ring-1 ring-inset ring-gray-300 text-gray-700 hover:bg-gray-50" }
            end
            size do
              xs { "text-xs px-2 py-1" }
              sm { "text-sm px-2.5 py-1.5" }
              default { "text-sm px-3 py-2" }
              lg { "text-base px-4 py-2.5" }
            end
            disabled do
              yes { "opacity-50 pointer-events-none" }
              no {}
            end
            full do
              yes { "w-full" }
              no {}
            end
          end
        end

        def classes = cn(style(variant:, size:, disabled:, full:), css)

        erb_template <<~ERB
          <button type="<%= type %>" class="<%= classes %>" <%= "disabled" if disabled %>><%= content %></button>
        ERB
      end
    end
  end
end
