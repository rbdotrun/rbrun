module Rbrun
  module Ui
    module Button
      # Renders a <button>, or an <a> when `href:` is given. HTML attrs (data:, id:, aria:, …) pass
      # straight through to the tag. Faithfully aligned with ../insitix Primitives::Button; the variants
      # + style machinery are rbrun's (StyleVariants + tailwind-merge).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(variant: :default, size: :default, type: "button", disabled: false, full: false,
                       href: nil, css: nil, **attrs)
          @variant  = variant
          @size     = size
          @type     = type
          @disabled = disabled
          @full     = full
          @href     = href
          @css      = css
          @attrs    = attrs
        end

        style do
          base { "inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition focus:outline-none focus-visible:ring-2 active:scale-[0.96] motion-reduce:active:scale-100 motion-reduce:transition-none" }
          variants do
            variant do
              default     { "bg-gray-900 text-white hover:bg-gray-800" }
              primary     { "bg-default-600 text-white hover:bg-default-500" }
              secondary   { "bg-gray-100 text-gray-900 hover:bg-gray-200" }
              outline     { "ring-1 ring-inset ring-gray-300 text-gray-700 hover:bg-gray-50" }
              white       { "bg-white ring-1 ring-inset ring-gray-300 text-gray-700 hover:bg-gray-50" }
              ghost       { "bg-transparent text-gray-700 hover:bg-gray-100" }
              destructive { "bg-red-600 text-white hover:bg-red-500" }
            end
            size do
              xs { "text-xs px-2 py-1" }
              sm { "text-sm px-2.5 py-1.5" }
              default { "text-sm px-3 py-2" }
              lg { "text-base px-4 py-2.5" }
            end
            disabled do
              yes { "opacity-50 pointer-events-none" }
              no { }
            end
            full do
              yes { "w-full" }
              no { }
            end
          end
        end

        def classes = cn(style(variant: @variant, size: @size, disabled: @disabled, full: @full), @css, @attrs.delete(:class))

        def call
          html_attrs = { class: classes, **@attrs }
          if @href
            link_to(@href, **html_attrs) { content }
          else
            tag.button(type: @type, disabled: @disabled, **html_attrs) { content }
          end
        end
      end
    end
  end
end
