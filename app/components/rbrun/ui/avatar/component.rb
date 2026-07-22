module Rbrun
  module Ui
    module Avatar
      # A round avatar: the image when `src` is present, otherwise a tinted tile with the first initial
      # of `name`. Faithfully ported from ../insitix (Primitives::Avatar).
      class Component < Rbrun::ApplicationViewComponent
        SIZES = { sm: "size-8 text-xs", md: "size-9 text-sm", lg: "size-12 text-base" }.freeze

        def initialize(src: nil, name: nil, icon: nil, size: :sm, **attrs)
          @src = src
          @name = name
          @icon = icon
          @size = size
          @attrs = attrs
        end

        def call
          base = class_names("shrink-0 rounded-full", SIZES.fetch(@size), @attrs.delete(:class))
          if @src.present?
            image_tag(@src, class: class_names(base, "object-cover"), alt: "", **@attrs)
          else
            tag.span(tile_content,
              class: class_names(base, "flex items-center justify-center bg-slate-200 font-semibold text-slate-600"),
              **@attrs)
          end
        end

        private

          def tile_content
            @icon.present? ? helpers.lucide_icon(@icon, class: "size-4") : initial
          end

          def initial = @name.to_s.strip.first&.upcase
      end
    end
  end
end
