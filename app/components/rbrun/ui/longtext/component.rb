module Rbrun
  module Ui
    module Longtext
      # Editorial long-form text — document descriptions, analyses: real typographic hierarchy for
      # headings, paragraphs and lists, meant to be READ. Distinct from the compact conversation `.md`.
      # Renders the given markdown inside the `.longtext` scope (styles in application.tailwind.css).
      #   <%= component("longtext", class: "p-6") { document_description } %>
      # Faithfully ported from ../insitix (Primitives::Longtext).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(**attrs)
          @attrs = attrs
        end

        def call
          tag.div(helpers.markdown(content.to_s), class: class_names("longtext", @attrs.delete(:class)), **@attrs)
        end
      end
    end
  end
end
