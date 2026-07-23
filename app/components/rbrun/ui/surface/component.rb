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

        # ─────────────────────────────────────────────────────────────────────────────────────────────
        # THE NORMALIZED HORIZONTAL INSET. Read this before adding any px-* anywhere in a surface.
        #
        # Every region — the header, the fixed strips (inputs/tabs) below it, the body, and the footer —
        # shares this ONE value, so the title, the search box, the rows, and the actions all line up on
        # the SAME left/right edge. It is the single source of horizontal rhythm. Only `size` changes it;
        # NEVER hardcode a px-* on a region, and NEVER let a caller pad a fixed_area/body itself — pass
        # the content bare and let the surface inset it. This is the whole point of the primitive.
        PADDING_X = { sm: "px-3", md: "px-4", lg: "px-6" }.freeze
        # ─────────────────────────────────────────────────────────────────────────────────────────────

        # Header scale preset: a DECLARED bar height (items-center does the vertical centering — NO
        # vertical padding) + the title type size. The meaningful header knob (the heading TAG, :h1/:h2,
        # is only semantics). :lg = page/dialog, :md = the more compact drawer.
        HEADER = {
          lg: { bar: "h-16", title: "text-xl" },
          md: { bar: "h-14", title: "text-lg" },
          sm: { bar: "h-12", title: "text-base" }
        }.freeze

        def initialize(title: nil, subtitle: nil, back: nil, close: false, heading: :h2, size: :lg,
                       preset: :card, inset: :padded, elevation: :none,
                       body_id: nil, footer_id: nil, css: nil)
          @title = title
          @subtitle = subtitle
          @back = back
          @close = close
          @heading = heading
          @size = size
          @preset = preset
          @inset = inset
          @elevation = elevation
          @body_id = body_id
          @footer_id = footer_id
          @css = css
        end

        attr_reader :title, :subtitle, :back, :close, :heading, :inset, :body_id, :footer_id

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

        # The one horizontal inset every region shares (see PADDING_X).
        def padding_x = PADDING_X.fetch(@size)

        # Fixed-height, items-centered header bar — the shared px, no vertical padding.
        def header_class
          class_names("flex flex-shrink-0 items-center justify-between gap-4 border-b border-slate-200",
                      padding_x, HEADER.fetch(@size)[:bar])
        end

        def title_class
          class_names("truncate font-semibold tracking-tight text-slate-800", HEADER.fetch(@size)[:title])
        end

        # A fixed strip below the header (an input toolbar, tabs) — shared px + a modest vertical.
        def fixed_area_class = class_names("flex-shrink-0 border-b border-slate-200 py-3", padding_x)

        # Pinned footer of actions — shared px + vertical.
        def footer_class
          class_names("flex flex-shrink-0 items-center justify-end gap-2 border-t border-slate-200 py-4", padding_x)
        end

        # The scroll region. :padded adds the shared px + a vertical; :centered pads via an inner max-w
        # column (ERB); :flush is full-bleed (a child that owns its own edges — the conversation, a list).
        def body_class = class_names("min-h-0 flex-1 overflow-y-auto", (padding_x if @inset == :padded), ("py-4" if @inset == :padded))

        def header? = title.present? || subtitle.present? || back.present? || close || actions?
      end
    end
  end
end
