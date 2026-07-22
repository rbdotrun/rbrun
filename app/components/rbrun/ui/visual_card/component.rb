module Rbrun
  module Ui
    module VisualCard
      # A visual card: cropped main IMAGE on top, TITLE below, optional DESCRIPTION + footer TAG.
      # Renders an <a> when `href:` is given (whole card is the link), else a <div>. No image → a branded
      # gradient placeholder carrying the title's initial. Faithfully ported from ../insitix.
      class Component < Rbrun::ApplicationViewComponent
        WRAP = "group flex flex-col overflow-hidden rounded-xl border border-slate-200 bg-white " \
               "no-underline transition-all duration-200 hover:-translate-y-0.5 hover:border-default-300 " \
               "hover:shadow-lg hover:shadow-slate-200/60"
        MEDIA = "relative aspect-[16/10] overflow-hidden border-b border-slate-200 bg-gradient-to-br from-default-200 via-default-300 to-default-500"
        IMG   = "h-full w-full object-cover transition-transform duration-300 group-hover:scale-[1.03]"
        SLOT  = "absolute inset-0 [&>*]:block [&>*]:size-full [&>*>*]:size-full [&>*>*]:rounded-none [&>*>*]:border-0 [&_img]:size-full [&_img]:object-cover"
        TITLE_SIZES = { md: "text-base", sm: "text-sm" }.freeze
        ICON = "size-20 text-white"

        renders_one :media

        def initialize(title:, href: nil, image: nil, icon: nil, description: nil, tag: nil, tag_icon: nil,
                       placeholder_icon: "image", size: :md, **attrs)
          @title = title
          @href = href
          @image = image
          @icon = icon
          @description = description
          @tag = tag
          @tag_icon = tag_icon
          @placeholder_icon = placeholder_icon
          @size = size
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
            return tag.div(media.to_s, class: SLOT) if media?
            return image_tag(@image, alt: @title.to_s, class: IMG) if @image
            return icon_media if @icon

            placeholder
          end

          def icon_media
            tag.div(lucide_icon(@icon, class: ICON), class: "flex h-full w-full items-center justify-center")
          end

          def placeholder
            safe_join([
              tag.div(
                tag.span(@title.to_s.strip[0]&.upcase, class: "text-5xl font-semibold tracking-tight text-white/85"),
                class: "flex h-full w-full items-center justify-center"
              ),
              lucide_icon(@placeholder_icon, class: "absolute bottom-3 right-3 size-5 text-white/40")
            ])
          end

          def text
            tag.div(class: "flex flex-1 flex-col gap-1.5 p-4") do
              safe_join(
                [
                  tag.h3(@title, class: class_names("line-clamp-2 font-semibold leading-snug text-slate-800 transition-colors group-hover:text-default-700", TITLE_SIZES.fetch(@size))),
                  description_tag,
                  footer
                ].compact
              )
            end
          end

          def description_tag
            return unless @description.present?

            tag.p(@description, class: "line-clamp-2 text-sm leading-relaxed text-slate-500")
          end

          def footer
            return unless @tag.present?

            tag.div(class: "mt-auto flex items-center gap-1.5 pt-3 text-xs text-slate-400") do
              safe_join([ (lucide_icon(@tag_icon, class: "size-3.5") if @tag_icon), tag.span(@tag) ].compact)
            end
          end
      end
    end
  end
end
