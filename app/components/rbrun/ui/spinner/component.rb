module Rbrun
  module Ui
    module Spinner
      class Component < Rbrun::ApplicationViewComponent
        option :size, default: proc { :default }
        option :variant, default: proc { :default }
        option :css, optional: true

        style do
          base { "inline-block animate-spin rounded-full border-2 border-current border-t-transparent" }
          variants do
            size do
              xs { "w-3 h-3" }
              sm { "w-4 h-4" }
              default { "w-5 h-5" }
              lg { "w-6 h-6" }
            end
            variant do
              default { "text-gray-500" }
              white { "text-white" }
              primary { "text-default-600" }
            end
          end
        end

        erb_template <<~ERB
          <span class="<%= cn(style(size:, variant:), css) %>" role="status" aria-label="loading"></span>
        ERB
      end
    end
  end
end
