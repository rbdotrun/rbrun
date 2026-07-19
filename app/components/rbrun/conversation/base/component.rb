module Rbrun
  module Conversation
    module Base
      # The full conversation: the streaming message timeline plus the composer. The Session page
      # renders this.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(session:)
          @session = session
        end

        attr_reader :session
      end
    end
  end
end
