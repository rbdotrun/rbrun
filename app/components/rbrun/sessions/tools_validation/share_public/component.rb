module Rbrun
  module Sessions
    module ToolsValidation
      module SharePublic
        # The share_public gate card. Public exposure must never be approved by accident, so the card
        # states plainly what is being granted: anyone with the link, no account.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

          def service_name = input["name"]
          def decided? = !@call.approval_pending?
          def approved? = @call.approval_approved?

          def public_url
            row = @call.session.messages.find_by(event_type: "tool_result", tool_use_id: tool_use_id)
            row&.payload&.dig("result", "data", "url") || row&.payload&.dig("result", "url")
          end
        end
      end
    end
  end
end
