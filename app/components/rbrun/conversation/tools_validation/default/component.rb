module Rbrun
  module Conversation
    module ToolsValidation
      module Default
        # The fallback gate: raw args (as code) + the shared Valider/Refuser action.
        class Component < Rbrun::Conversation::ToolsValidation::Base
        end
      end
    end
  end
end
