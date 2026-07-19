module Rbrun
  module Ui
    module CodeBlock
      class Component < Rbrun::ApplicationViewComponent
        option :code
        option :language, default: proc { "text" }
        option :css, optional: true

        def classes = cn("rounded-md bg-gray-900 text-gray-100 text-xs p-3 overflow-x-auto", css)

        erb_template <<~ERB
          <pre class="<%= classes %>"><code class="language-<%= language %>"><%= code %></code></pre>
        ERB
      end
    end
  end
end
