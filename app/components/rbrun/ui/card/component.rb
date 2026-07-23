module Rbrun
  module Ui
    module Card
      # A titled inline surface — a thin wrapper over Ui::Surface (preset :card). Kept as its own name
      # for the ergonomic component("card", title:, subtitle:) call; all structure lives in Surface, so
      # a card reads exactly like every other panel (header + body) and shares the natural-scroll model.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(title: nil, subtitle: nil, css: nil)
          @title = title
          @subtitle = subtitle
          @css = css
        end

        def call
          component("surface", preset: :card, elevation: :md,
                    title: @title, description: @subtitle, css: @css) do |s|
            s.with_body { content }
          end
        end
      end
    end
  end
end
