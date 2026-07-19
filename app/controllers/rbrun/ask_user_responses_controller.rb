module Rbrun
  # The ask_user gate endpoint. A frozen ask_user tool_use row carries the form_spec; the user's picks
  # arrive here, become the call's own tool_result, and resume the turn — via the shared ResolvesGate
  # dance. The tool never runs in Ruby; the submission IS its operation.
  class AskUserResponsesController < Rbrun::ApplicationController
    include Rbrun::ResolvesGate

    def create
      row = pending_gate
      # Claim lost (already answered by another tab): nothing to record or resume.
      return head :no_content unless claim_gate!(row, status: "answered")

      answers = permitted_answers
      record_gate_result(row, { "answers" => answers })
      resume_turn(row, AskUserTurnJob, answers_nudge(answers))
      render_gate_band(row)
    end

    private

    # { "key" => [values] } — always an array, whichever the input kind.
    def permitted_answers
      raw = params[:answers]
      return {} if raw.blank?

      raw = raw.permit!.to_h if raw.respond_to?(:permit!)
      raw.to_h { |key, value| [ key.to_s, Array(value).map(&:to_s) ] }
    end

    def answers_nudge(answers)
      picks = answers.map { |key, values| "#{key}=#{values.join(',')}" }.join("; ")
      "The user answered: #{picks}. Continue with these choices."
    end
  end
end
