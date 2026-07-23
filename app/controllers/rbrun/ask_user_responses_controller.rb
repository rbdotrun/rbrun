module Rbrun
  # The ask_user gate endpoint. A frozen ask_user tool_use row carries the form_spec; the user's picks
  # arrive here, are VALIDATED against that frozen spec (the trust boundary — the agent declared the
  # options, so a submission can only be within them), become the call's own tool_result, and resume
  # the turn with a label-resolved recap — via the shared ResolvesGate dance. The tool never runs in
  # Ruby; the (validated) submission IS its operation.
  class AskUserResponsesController < Rbrun::ApplicationController
    include Rbrun::ResolvesGate

    def create
      row = pending_gate
      spec = Rbrun::AskUserFormSpec.new(row.payload.dig("input", "form_spec"))
      submitted = submitted_answers

      # Trust boundary FIRST — before the claim: a required question skipped, a value not in the
      # declared options, or an unknown field is rejected; nothing is claimed, recorded, or resumed.
      errors = spec.errors(submitted)
      return render(plain: errors.join("; "), status: :unprocessable_entity) if errors.any?

      # Claim lost (already answered by another tab): nothing to record or resume.
      return head :no_content unless claim_gate!(row, status: "answered")

      answers = submitted.slice(*spec.keys) # only the declared keys are recorded
      record_gate_result(row, { "answers" => answers })
      resume_turn(row, AskUserTurnJob, spec.recap(answers))
      render_gate_band(row)
    end

    private

      # The raw submission, string-keyed with array values — passed to the validator as-is (so unknown
      # keys are caught), then sliced to the declared keys once validated. The spec is the boundary, not
      # a permit-list.
      def submitted_answers
        raw = params[:answers]
        return {} if raw.blank?

        hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
        hash.to_h { |key, value| [ key.to_s, Array(value).map(&:to_s).reject(&:blank?) ] }
      end
  end
end
