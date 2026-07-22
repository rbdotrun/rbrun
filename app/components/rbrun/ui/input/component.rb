module Rbrun
  module Ui
    module Input
      # A bare input on the shared form surface — no label/error chrome (that's Field). For places that
      # own their own label markup (filter drawer, inline toolbars) but still want the ONE canonical
      # input look. `size: :sm` picks the tighter surface. Faithfully ported from ../insitix.
      class Component < Rbrun::ApplicationViewComponent
        SURFACE = { md: Rbrun::Ui::Field::Component::INPUT, sm: "form-input-sm" }.freeze

        def initialize(name:, type: "text", value: nil, placeholder: nil, size: :md, **attrs)
          @name = name
          @type = type
          @value = value
          @placeholder = placeholder
          @size = size
          @attrs = attrs
        end

        def call
          tag.input(
            type: @type, name: @name, value: @value, placeholder: @placeholder,
            class: class_names(SURFACE.fetch(@size), @attrs.delete(:class)), **@attrs
          )
        end
      end
    end
  end
end
