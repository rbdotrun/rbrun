module Rbrun
  module Conversation
    module Default
      # The default conversation, full width.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(session:)
          @session = session
        end

        def call
          tag.div(render(Rbrun::Conversation::Base::Component.new(session: @session)), class: "h-full w-full")
        end
      end
    end
  end
end
