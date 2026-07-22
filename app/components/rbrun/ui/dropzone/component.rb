module Rbrun
  module Ui
    module Dropzone
      # A styled file picker + drag-and-drop target. Presentation only — it wraps a real <input type=file>
      # under `name`, so it posts with whatever form it sits in. `name` is the exact input name (append
      # "[]" for multiple). Faithfully ported from ../insitix (Primitives::Dropzone).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(name:, accept: nil, multiple: false, hint: nil, label: nil)
          @name = name
          @accept = accept
          @multiple = multiple
          @hint = hint
          @label = label
        end

        private

          attr_reader :name, :accept, :multiple, :hint, :label
      end
    end
  end
end
