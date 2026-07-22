module Rbrun
  module Ui
    module Textarea
      # A labeled textarea on the shared form surface. Faithfully ported from ../insitix.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(label:, name:, value: nil, rows: 4, error: nil, **attrs)
          @label = label
          @name = name
          @value = value
          @rows = rows
          @error = error
          @attrs = attrs
        end

        def call
          tag.label(class: "flex flex-col gap-1.5") do
            safe_join([
              (tag.span(@label, class: "text-sm font-medium text-slate-700") if @label.present?),
              tag.textarea(@value.to_s, name: @name, id: @name, rows: @rows,
                           "aria-invalid": (@error.present? || nil),
                           class: class_names("#{Rbrun::Ui::Field::Component::INPUT} min-h-24", @attrs.delete(:class)),
                           **@attrs),
              (tag.p(@error, class: "text-xs text-red-600") if @error.present?)
            ].compact)
          end
        end
      end
    end
  end
end
