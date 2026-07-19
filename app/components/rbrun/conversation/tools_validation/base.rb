module Rbrun
  module Conversation
    module ToolsValidation
      # The contract every tool-call validation card inherits: handed the pending tool_use row
      # (`call:`), it derives everything from it. Subclasses render their own card via a sidecar erb.
      class Base < Rbrun::ApplicationViewComponent
        include Rbrun::ConversationHelper

        def initialize(call:)
          @call = call
        end

        private

        # NOT attr_reader :call — `call` is ViewComponent's own render method.
        def tool_use_id = @call.tool_use_id
        def input = @call.payload["input"] || {}
        def tool_name = @call.payload["name"]
      end
    end
  end
end
