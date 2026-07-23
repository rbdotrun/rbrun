module Rbrun
  module Sessions
    module ToolsValidation
      module AskUser
        # The ask_user gate card: a radio/checkbox stepper while pending, the picked answers (label-
        # resolved) once answered. Reads the frozen form_spec through Rbrun::AskUserFormSpec — the SAME
        # read model the controller validates against, so the card and the validator never disagree.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

            def spec = @spec ||= Rbrun::AskUserFormSpec.new(input["form_spec"])

            def answered? = @call.approval_answered?

            # { key => [values] } off the call's tool_result row.
            def answers
              @answers ||= begin
                result = @call.session.messages.find_by(event_type: "tool_result", tool_use_id:)
                result&.payload&.dig("result", "answers") || {}
              end
            end

            def submit_path       = helpers.rbrun.ask_user_response_path(tool_use_id)
            def field_name(question) = spec.multiple?(question["key"]) ? "answers[#{question['key']}][]" : "answers[#{question['key']}]"
        end
      end
    end
  end
end
