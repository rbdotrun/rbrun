module Rbrun
  module Ui
    module InputSelect
      # A labeled <select> with optional optgroups. (insitix enhances this with a React combobox; rbrun is
      # Stimulus-only, so this is the native control — progressive enhancement without the React mount.)
      # `options` = [[label, value], …] or, when grouped: [[group_label, [[label, value], …]], …].
      # `submit_on_change:` adds an onchange that submits the enclosing form. Faithfully adapted.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(name:, options:, label: nil, value: nil, grouped: false,
                       include_blank: true, submit_on_change: false, error: nil, **attrs)
          @label = label
          @name = name
          @options = options
          @value = value
          @grouped = grouped
          @include_blank = include_blank
          @submit_on_change = submit_on_change
          @error = error
          @attrs = attrs
        end

        private

          attr_reader :label, :name, :options, :value, :grouped, :include_blank,
                      :submit_on_change, :error, :attrs
      end
    end
  end
end
