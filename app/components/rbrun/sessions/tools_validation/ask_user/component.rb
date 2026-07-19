module Rbrun
  module Sessions
    module ToolsValidation
      module AskUser
        # The ask_user gate card: a radio/checkbox stepper while pending, the picked answers once
        # answered. Built from the frozen form_spec; the answers (when answered) are read off the
        # call's own tool_result (written by AskUserResponsesController).
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

          def spec  = @spec ||= (input["form_spec"] || {})
          def title = spec["title"]
          def steps = spec["steps"] || []

          def answered? = @call.approval_answered?

          # { key => [values] } off the call's tool_result row.
          def answers
            @answers ||= begin
              result = @call.session.messages.find_by(event_type: "tool_result", tool_use_id: tool_use_id)
              result&.payload&.dig("result", "answers") || {}
            end
          end

          def submit_path = helpers.rbrun.ask_user_response_path(tool_use_id)

          def field_name(question) = question["input"] == "checkbox" ? "answers[#{question['key']}][]" : "answers[#{question['key']}]"
          def multi?(question)     = question["input"] == "checkbox"
        end
      end
    end
  end
end
