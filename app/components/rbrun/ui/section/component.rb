module Rbrun
  module Ui
    module Section
      # A titled content section — a normalized header (title) above yielded body, divided from what
      # precedes it. The caller owns the body layout. Faithfully ported from ../insitix (Primitives::Section).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(title:)
          @title = title
        end
      end
    end
  end
end
