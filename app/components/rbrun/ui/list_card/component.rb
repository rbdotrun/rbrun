module Rbrun
  module Ui
    module ListCard
      # A compact HORIZONTAL card — the list cousin of VisualCard. A small media box on the LEFT (icon on
      # a branded panel, image, the `media` slot, or a placeholder initial), TITLE + a one-line
      # DESCRIPTION excerpt on the RIGHT. An <a> when `href:` is given, else a <div>. Faithfully ported.
      class Component < Rbrun::ApplicationViewComponent
        WRAP  = "group flex items-center gap-3 rounded-lg border border-slate-200 bg-white p-2.5 " \
                "no-underline text-left transition-colors hover:border-default-300 hover:bg-default-50"
        MEDIA = "flex size-11 shrink-0 items-center justify-center overflow-hidden rounded-md " \
                "bg-gradient-to-br from-default-100 via-default-200 to-default-400 text-white"
        IMG   = "size-full object-cover"

        renders_one :media

        def initialize(title:, href: nil, icon: nil, image: nil, description: nil, **attrs)
          @title = title
          @href = href
          @icon = icon
          @image = image
          @description = description
          @attrs = attrs
        end

        def call
          body = safe_join([ media_box, text ])
          classes = class_names(WRAP, @attrs.delete(:class))
          return link_to(body, @href, class: classes, **@attrs) if @href

          tag.div(body, class: classes, **@attrs)
        end

        private

          def media_box = tag.div(media_content, class: MEDIA)

          def media_content
            return media.to_s if media?
            return image_tag(@image, alt: @title.to_s, class: IMG) if @image
            return lucide_icon(@icon, class: "size-5") if @icon.present?

            tag.span(@title.to_s.strip[0]&.upcase, class: "text-sm font-semibold")
          end

          def text
            tag.div(class: "min-w-0 flex-1") do
              safe_join(
                [
                  tag.span(@title, class: "block truncate text-sm font-medium text-slate-800"),
                  description_tag
                ].compact
              )
            end
          end

          def description_tag
            return unless @description.present?

            tag.span(@description, class: "mt-0.5 block truncate text-xs leading-snug text-slate-500")
          end
      end
    end
  end
end
