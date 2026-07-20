module Rbrun
  module Sessions
    module ToolsValidation
      module RequestSecrets
        # The request_secrets gate card: a SECURE (password) input per declared key while pending; once
        # answered, only the KEY NAMES that were stored (never a value). Reads the frozen declaration
        # through SecretsFormSpec — the same read model the controller validates against.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

          def spec = @spec ||= Rbrun::SecretsFormSpec.new(input)

          def answered? = @call.approval_answered?

          def stored_keys
            @stored_keys ||= begin
              row = @call.session.messages.find_by(event_type: "tool_result", tool_use_id: tool_use_id)
              Array(row&.payload&.dig("result", "stored_keys"))
            end
          end

          def submit_path = helpers.rbrun.secrets_submission_path(tool_use_id)
        end
      end
    end
  end
end
