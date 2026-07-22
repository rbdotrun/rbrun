module Rbrun
  module Ui
    module Select
      # Labeled <select>. `options` = [[label, value], …] or, when grouped: true,
      # [[group_label, [[label, value], …]], …]. Faithfully ported from ../insitix (Primitives::Select).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(label:, name:, options:, value: nil, grouped: false, include_blank: true, error: nil)
          @label = label
          @name = name
          @options = options
          @value = value
          @grouped = grouped
          @include_blank = include_blank
          @error = error
        end

        def call
          tag.label(class: "flex flex-col gap-1.5") do
            safe_join([
              tag.span(@label, class: "text-sm font-medium text-slate-700"),
              tag.select(options_html, name: @name, id: @name,
                         "aria-invalid": (@error.present? || nil), class: Rbrun::Ui::Field::Component::INPUT),
              (tag.p(@error, class: "text-xs text-red-600") if @error.present?)
            ].compact)
          end
        end

        private

          def options_html
            blank = @include_blank ? options_for_select([ [ "—", "" ] ]) : "".html_safe
            opts = @grouped ? grouped_options_for_select(@options, @value) :
                              options_for_select(@options, @value)
            safe_join([ blank, opts ])
          end
      end
    end
  end
end
