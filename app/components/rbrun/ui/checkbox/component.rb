module Rbrun
  module Ui
    module Checkbox
      # A custom checkbox: an appearance-none box (size-4) with a check/indeterminate SVG overlaid via
      # the `group-has-*` pattern — the SVG path can't be a `peer` sibling of the input, so it's gated
      # on the wrapping `group` instead. Extra attrs pass through to the input. Faithfully ported.
      class Component < Rbrun::ApplicationViewComponent
        BOX = "col-start-1 row-start-1 size-4 cursor-pointer appearance-none rounded border border-slate-300 bg-white text-default-600 " \
              "checked:border-default-600 checked:bg-default-600 indeterminate:border-default-600 indeterminate:bg-default-600 " \
              "focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-default-600 " \
              "disabled:border-slate-300 disabled:bg-slate-100 disabled:checked:bg-slate-100 forced-colors:appearance-auto"

        def initialize(name: nil, value: "1", checked: false, **attrs)
          @name = name
          @value = value
          @checked = checked
          @attrs = attrs
        end

        def input_options
          { class: class_names(BOX, @attrs.delete(:class)) }.merge(@attrs)
        end

        erb_template <<~ERB
          <span class="group relative grid size-4 shrink-0">
            <%= check_box_tag(@name, @value, @checked, input_options) %>
            <svg class="pointer-events-none col-start-1 row-start-1 size-4 self-center justify-self-center stroke-white" viewBox="0 0 18 18" fill="none">
              <%# paths centered on the 18×18 viewBox so the mark sits dead-center in the box %>
              <path class="opacity-0 group-has-checked:opacity-100" d="M4 9L7.5 12.5L14 5.5" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
              <path class="opacity-0 group-has-indeterminate:opacity-100" d="M5 9H13" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
            </svg>
          </span>
        ERB
      end
    end
  end
end
