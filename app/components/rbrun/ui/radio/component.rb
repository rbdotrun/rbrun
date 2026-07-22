module Rbrun
  module Ui
    module Radio
      # A custom radio, styled to match Checkbox: an appearance-none disc with a white centre dot
      # revealed on check via the `peer` pattern. Extra attrs pass through to the input. Faithfully
      # ported from ../insitix (Primitives::Radio).
      class Component < Rbrun::ApplicationViewComponent
        DISC = "peer col-start-1 row-start-1 size-4 cursor-pointer appearance-none rounded-full border border-slate-300 bg-white " \
               "checked:border-default-600 checked:bg-default-600 " \
               "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-default-600 " \
               "disabled:border-slate-300 disabled:bg-slate-100"

        def initialize(name:, value:, checked: false, **attrs)
          @name = name
          @value = value
          @checked = checked
          @attrs = attrs
        end

        def input_options
          { class: class_names(DISC, @attrs.delete(:class)) }.merge(@attrs)
        end

        erb_template <<~ERB
          <span class="relative grid size-4 shrink-0">
            <%= radio_button_tag(@name, @value, @checked, input_options) %>
            <span class="pointer-events-none col-start-1 row-start-1 size-1.5 self-center justify-self-center rounded-full bg-white opacity-0 peer-checked:opacity-100"></span>
          </span>
        ERB
      end
    end
  end
end
