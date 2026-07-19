module Rbrun
  module Sessions
    module Turn
      # One exchange: the user line, then the assistant response rendered by the Timeline over this
      # turn's event-log rows. turn_<id> is the anchor a turn-open re-broadcast replaces.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(user_message:, messages:, working: false)
          @user_message = user_message
          @messages = messages
          @working = working
        end

        attr_reader :user_message, :messages, :working
      end
    end
  end
end
