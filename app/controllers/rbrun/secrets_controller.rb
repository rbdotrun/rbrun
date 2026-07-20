module Rbrun
  # The request_secrets gate endpoint. A frozen request_secrets tool_use row carries the KEY declaration;
  # the user's values arrive here, are validated against that frozen spec (trust boundary), ENCRYPTED into
  # RepoSecret (repo-scoped), and the turn resumes with a KEYS-ONLY nudge. Values never enter the
  # tool_result, the timeline, the nudge, or the logs — only the fact that keys were set. Shared
  # ResolvesGate dance; the tool never runs in Ruby.
  class SecretsController < Rbrun::ApplicationController
    include Rbrun::ResolvesGate

    def create
      row  = pending_gate
      spec = Rbrun::SecretsFormSpec.new(row.payload["input"])
      submitted = submitted_secrets

      # Trust boundary FIRST — before the claim: a required key missing or an unknown field is rejected;
      # nothing is claimed, stored, or resumed.
      errors = spec.errors(submitted)
      return render(plain: errors.join("; "), status: :unprocessable_entity) if errors.any?

      return head :no_content unless claim_gate!(row, status: "answered")

      stored = store_secrets!(row.session, spec, submitted)
      record_gate_result(row, { "stored_keys" => stored }) # KEYS ONLY — never a value
      resume_turn(row, SecretsTurnJob, spec.stored_recap(stored))
      render_gate_band(row)
    end

    private

    # Encrypt + upsert each declared, non-blank value as a repo-scoped RepoSecret. Returns the key names.
    def store_secrets!(session, spec, submitted)
      repo = session.worktree.repo
      submitted.slice(*spec.keys).filter_map do |key, value|
        next if value.to_s.empty?

        rec = Rbrun::RepoSecret.for_tenant(session.tenant).find_or_initialize_by(repo: repo, key: key)
        rec[Rbrun.config.tenancy_key] = session.tenant
        rec.update!(value: value)
        key
      end
    end

    # Raw submission → string-keyed { key => value } (single value per key). Sliced to declared keys
    # only once validated. The frozen spec is the boundary, not a permit-list.
    def submitted_secrets
      raw = params[:secrets]
      return {} if raw.blank?

      hash = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
      hash.to_h { |key, value| [ key.to_s, value.to_s ] }
    end
  end
end
