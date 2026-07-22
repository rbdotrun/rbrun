module Rbrun
  module Ui
    module SearchInput
      # A search box: a leading icon, an input on the shared form surface, and a clear (X) button in a
      # pill. Debounced autosearch via the `search-bar` controller (submits the enclosing GET form). `id`
      # stays stable so it can be turbo-permanent (keeps focus/value across the debounced GET). Faithfully
      # ported from ../insitix (Primitives::SearchInput).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(id:, value: nil, name: "q", placeholder: "Search…")
          @id = id
          @value = value
          @name = name
          @placeholder = placeholder
        end

        attr_reader :id, :value, :name, :placeholder
      end
    end
  end
end
