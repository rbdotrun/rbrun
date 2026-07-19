module Rbrun
  module Sessions
    module ToolsValidation
      module ValidateStep
        # The validate_step gate card: the step being completed + the agent's summary, with the shared
        # yes/no approval actions while pending; the outcome once decided.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

          def summary = input["summary"]
          def decided? = !@call.approval_pending?
          def approved? = @call.approval_approved?

          def result
            @result ||= @call.session.messages.find_by(event_type: "tool_result", tool_use_id: tool_use_id)
                             &.payload&.dig("result") || {}
          end

          # After approval current_step has advanced, so read the completed step's title from the result.
          def step_title = result["step"].presence || Rbrun::Workflow::Run.new(@call.session).current_step&.title
        end
      end
    end
  end
end
