module Rbrun
  module Ui
    module Field
      # A labeled form input (label + input + optional error). One place for the input chrome so forms
      # don't hand-roll label+input markup. The shared surface is the `form-input` Tailwind utility
      # (see application.tailwind.css) — the same class Input/Select/Textarea and the date-picker trigger
      # use. Faithfully ported from ../insitix (Primitives::Field).
      class Component < Rbrun::ApplicationViewComponent
        INPUT = "form-input"

        def initialize(label:, name:, type: "text", value: nil, placeholder: nil, autocomplete: nil,
                       autofocus: false, required: true, error: nil, **attrs)
          @label = label
          @name = name
          @type = type
          @value = value
          @placeholder = placeholder
          @autocomplete = autocomplete
          @autofocus = autofocus
          @required = required
          @error = error
          @attrs = attrs
        end

        def call
          tag.label(class: "flex flex-col gap-1.5") do
            safe_join([ label_span, input_tag, error_tag ].compact)
          end
        end

        private

          def label_span = tag.span(@label, class: "text-sm font-medium text-slate-700")

          def input_tag
            tag.input(
              type: @type, name: @name, id: @name, value: @value,
              placeholder: @placeholder, autocomplete: @autocomplete, autofocus: @autofocus,
              required: @required, "aria-invalid": (@error.present? || nil),
              class: class_names(INPUT, @attrs.delete(:class)), **@attrs
            )
          end

          def error_tag
            tag.p(@error, class: "text-xs text-red-600") if @error.present?
          end
      end
    end
  end
end
