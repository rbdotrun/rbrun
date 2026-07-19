module Rbrun
  module Tools
    # Ask the user to CHOOSE from options, then continue with their answer. A custom gate: it ends the
    # run (needs_approval) and freezes as a pending tool_use row carrying the form_spec; the card
    # renders a radio/checkbox stepper, and the picks resume the turn (AskUserResponsesController). The
    # deterministic sibling of a free-text question — use it the moment a next step needs a pick.
    #
    # No execute: a gate tool's operation is the user's submission; custom_approval! supplies the
    # degrade default a stray hand-call needs.
    class AskUser < Rbrun::ApplicationTool
      custom_approval! submit: :ask_user_response

      description <<~TXT
        Ask the user to CHOOSE from options, then continue with their answer. Use whenever a useful
        next step needs a selection — NEVER a free-text question. `form_spec` is an object:
          { "title": "Narrow it down",
            "steps": [ { "title": "Color",
              "questions": [
                { "key": "color", "label": "Which color?", "input": "radio",
                  "options": [ {"value":"red","label":"Red"}, {"value":"blue","label":"Blue"} ],
                  "required": true } ] } ] }
        `input` is "radio" (single choice) or "checkbox" (multiple). Options are inline (value+label).
        No text entry — only radios / checkboxes.
      TXT

      parameter :form_spec, type: "object",
                description: "the question form: { title, steps: [ { title, questions: [ { key, label, input, options, required } ] } ] }",
                required: true
    end
  end
end
