module Rbrun
  module Sessions
    module ToolsValidation
      module WorkflowCreate
        # The workflow_create gate card: the proposed plan + Apply/Save/Cancel while pending, a one-line
        # recap (off the tool_result) once decided.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

            def label = input["label"]
            def goal = input["goal"]
            def steps = Array(input["steps"])

            def decided? = !@call.approval_pending?

            def outcome
              @outcome ||= begin
                row = @call.session.messages.find_by(event_type: "tool_result", tool_use_id:)
                row&.payload&.dig("result") || {}
              end
            end

            def recap
              case outcome["decision"]
              when "apply" then "Applied — “#{outcome['label']}” is now running."
              when "save"  then "Saved “#{outcome['label']}” to the library."
              else "Declined — no workflow created."
              end
            end

            def submit_path = helpers.rbrun.workflow_decision_path(tool_use_id)
        end
      end
    end
  end
end
