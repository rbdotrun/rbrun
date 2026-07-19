module Rbrun
  module Sessions
    module Default
      # The default conversation, full width.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(session:)
          @session = session
        end

        def call
          tag.div(render(Rbrun::Sessions::Base::Component.new(session: @session)), class: "h-full w-full")
        end
      end
    end
  end
end
