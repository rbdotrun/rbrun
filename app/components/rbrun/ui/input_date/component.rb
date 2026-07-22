module Rbrun
  module Ui
    module InputDate
      # A date / month field. (insitix enhances this with a React calendar; rbrun is Stimulus-only, so this
      # is the native <input type=date|month> — progressive enhancement without the React mount.) `mode` is
      # :date (YYYY-MM-DD) or :month (YYYY-MM). Faithfully adapted from ../insitix.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(label:, name:, value: nil, mode: :date, error: nil)
          @label = label
          @name = name
          @value = value
          @mode = mode
          @error = error
        end

        private

          attr_reader :label, :name, :value, :mode, :error
      end
    end
  end
end
