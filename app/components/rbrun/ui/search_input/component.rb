module Rbrun
  module Ui
    module SearchInput
      # The reusable search box for a `command`-driven filtered list: a leading search icon, an input,
      # and a right-side affordance that is a SPINNER while a search request is in flight and a CLEAR (X)
      # button when the field has a value at rest. It carries only `command` targets/actions — drop it
      # inside a `data-controller="command"` region that also holds the results `<turbo-frame
      # data-command-target="frame">` (and an optional skeleton <template>). Reusable anywhere that
      # pattern recurs. Ported/evolved from ../insitix (Primitives::SearchInput).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(name: "q", value: nil, placeholder: "Search…")
          @name = name
          @value = value
          @placeholder = placeholder
        end

        attr_reader :name, :value, :placeholder
      end
    end
  end
end
