module Rbrun
  module Ui
    module Switch
      # A toggle switch: a visually-hidden peer checkbox drives the track; an optional hidden "0" makes
      # it submit a value even when off (form-friendly). Extra attrs (onchange, data-*) pass through to
      # the checkbox. Faithfully ported from ../insitix (Primitives::Switch).
      class Component < Rbrun::ApplicationViewComponent
        BASE = "bg-default-200 peer-focus:outline-none peer-focus:ring-4 peer-focus:ring-default-300 " \
               "rounded-full peer peer-checked:after:translate-x-full peer-checked:after:border-white " \
               "after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white " \
               "after:border-default-300 after:border after:rounded-full after:transition-all " \
               "peer-checked:bg-default-600 shrink-0 relative"

        SIZES = { md: "w-11 h-6 after:h-5 after:w-5", sm: "w-7 h-4 after:h-3 after:w-3" }.freeze

        def initialize(name:, label: nil, checked: false, value: "1", include_hidden: true, size: :md, **attrs)
          @name = name
          @label = label
          @checked = checked
          @value = value
          @include_hidden = include_hidden
          @size = size
          @attrs = attrs
        end

        def call
          tag.label(class: "relative isolate inline-flex cursor-pointer items-center") do
            safe_join([
              (@include_hidden ? hidden_field_tag(@name, "0", id: nil) : nil),
              check_box_tag(@name, @value, @checked, class: "peer sr-only", **@attrs),
              tag.div("", class: class_names(BASE, SIZES.fetch(@size))),
              (@label ? tag.span(@label, class: "ml-3 text-sm font-medium text-slate-700") : nil)
            ].compact)
          end
        end
      end
    end
  end
end
