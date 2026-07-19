module Rbrun
  module Sessions
    module ToolsValidation
      module Default
        # The fallback gate: raw args (as code) + the shared Valider/Refuser action.
        class Component < Rbrun::Sessions::ToolsValidation::Base
        end
      end
    end
  end
end
