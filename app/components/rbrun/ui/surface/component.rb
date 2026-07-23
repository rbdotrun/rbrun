module Rbrun
  module Ui
    module Surface
      # The one titled, scrollable surface: header → fixed strips → body → footer (→ side panel). Every
      # panel in the app (main page, dialog, drawer, confirm, inline card) composes this; only chrome
      # (preset) / inset / elevation differ. It imposes NO height of its own — as a min-h-0 flex child of
      # a height-bearing flex-column container (the <dialog>/drawer/<main>) the body scrolls the space
      # left after header/footer; with no constraint it grows and nothing scrolls. (Replaces page_header:
      # the header is rendered inline here, nowhere else.)
      class Component < Rbrun::ApplicationViewComponent
        renders_one  :actions
        renders_many :fixed_areas
        renders_one  :body
        renders_one  :footer
        renders_one  :side_panel

        # Body padding by inset. :centered pads via an inner max-w column (ERB) so the column scrolls.
        INSET = { padded: "p-6", centered: nil, flush: nil }.freeze

        def initialize(title: nil, back: nil, close: false, description: nil,
                       preset: :card, inset: :padded, elevation: :none,
                       body_id: nil, footer_id: nil, css: nil)
          @title = title
          @back = back
          @close = close
          @description = description
          @preset = preset
          @inset = inset
          @elevation = elevation
          @body_id = body_id
          @footer_id = footer_id
          @css = css
        end

        attr_reader :title, :back, :close, :description, :inset, :body_id, :footer_id

        style do
          base { "flex min-h-0 min-w-0 flex-auto flex-col" }
          variants do
            preset do
              card   { "rounded-lg border bg-white" }
              dialog { "rounded-xl border bg-white" }
              drawer { "rounded-none border-l bg-white" }
              bare   { "" }
            end
            elevation do
              none { }
              sm { "shadow-sm" }
              md { "shadow-md" }
              lg { "shadow-xl" }
            end
          end
        end

        def root_class = cn(style(preset: @preset, elevation: @elevation), @css)

        def body_class = class_names("min-h-0 flex-1 overflow-y-auto", INSET[@inset])

        def header? = title.present? || back.present? || close || description.present? || actions?
      end
    end
  end
end
