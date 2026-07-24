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

            # The tool's own data, via the model that owns the envelope shape — not a hand-dug payload.
            def result = @result ||= @call.tool_result_data

            # Which step this card is about. Once decided, it is whatever validate_step actually recorded
            # (current_step has since ADVANCED, so reading it then names the wrong step); while pending,
            # the step awaiting confirmation. Two distinct states, answered from the right source each
            # time — not one read with a fallback papering over the other.
            def step_title
              return Rbrun::Workflow::Run.new(@call.session).current_step&.title unless decided?

              result["step"]
            end
        end
      end
    end
  end
end
