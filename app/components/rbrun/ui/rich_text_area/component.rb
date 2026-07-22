module Rbrun
  module Ui
    module RichTextArea
      # A rich-text form field backed by TipTap (vanilla Stimulus — see rich_text_area_controller.js).
      # Submits editor HTML through a hidden input under `name`. Same label/error chrome as Field.
      # Faithfully ported from ../insitix (Primitives::RichTextArea); the insitix-specific AI-assist
      # button is dropped (no equivalent route here).
      class Component < Rbrun::ApplicationViewComponent
        # Format buttons: lucide icon + TipTap chain command + isActive type (+ level).
        TOOLS = [
          { icon: "bold",         command: "toggleBold",        type: "bold" },
          { icon: "italic",       command: "toggleItalic",      type: "italic" },
          { icon: "pilcrow",      command: "setParagraph",      type: "paragraph" },
          { icon: "heading-1",    command: "toggleHeading",     type: "heading", level: 1 },
          { icon: "heading-2",    command: "toggleHeading",     type: "heading", level: 2 },
          { icon: "heading-3",    command: "toggleHeading",     type: "heading", level: 3 },
          { icon: "list",         command: "toggleBulletList",  type: "bulletList" },
          { icon: "list-ordered", command: "toggleOrderedList", type: "orderedList" }
        ].freeze

        # Editorial typography inside the editor — ported verbatim. Uses the repo's `default` OKLCH ramp.
        CONTENT = %w[
          [&_h1]:font-semibold [&_h2]:font-semibold [&_h3]:font-semibold [&_h4]:font-semibold
          [&_h1]:!text-default-600 [&_h2]:!text-default-600 [&_h3]:!text-default-600 [&_h4]:!text-default-600
          [&_h1]:text-3xl [&_h1]:mb-6 [&_h2]:text-2xl [&_h2]:mb-4 [&_h3]:text-xl [&_h3]:mb-2 [&_h4]:text-lg [&_h4]:mb-2
          [&_p]:mb-2 [&_strong]:font-semibold
          [&_ul]:list-disc [&_ul]:ml-6 [&_ul]:mb-4 [&_ol]:list-decimal [&_ol]:ml-6 [&_ol]:mb-4 [&_li]:mb-1
          [&_a]:text-default-600 [&_a]:underline [&_a]:cursor-pointer
        ].freeze

        BUTTON = "flex h-8 items-center px-2 text-default-400 hover:bg-white hover:text-default-600"

        def initialize(name:, value: nil, label: nil, placeholder: nil, rows: 4, show_menubar: true, error: nil)
          @name = name
          @value = value
          @label = label
          @placeholder = placeholder
          @rows = rows
          @show_menubar = show_menubar
          @error = error
        end

        attr_reader :name, :value, :label, :placeholder, :show_menubar, :error

        def tools        = TOOLS
        def button_class = BUTTON
        # Same input surface as every other field, plus the editorial typography.
        def editor_class = class_names(Rbrun::Ui::Field::Component::INPUT, *CONTENT, "h-auto")
        # rows * line-height + padding.
        def min_height = "min-height: #{@rows.to_i * 24 + 32}px"
      end
    end
  end
end
