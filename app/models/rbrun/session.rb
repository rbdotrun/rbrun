module Rbrun
  # ONE conversation: an event log + the sandbox it works in, rooted to a tenant. The turn loop
  # (#run_turn) arrives in Phase 5; here a Session persists and resolves its sandbox.
  class Session < ApplicationRecord
    include Rbrun::Tenanted

    has_many :messages, -> { order(:created_at, :id) },
             class_name: "Rbrun::SessionMessage", dependent: :destroy

    enum :status,
         { idle: "idle", working: "working", needs_approval: "needs_approval", done: "done", failed: "failed" },
         default: "idle"

    # The conversation's box, addressed by label (see Rbrun::Sandbox). Memoized per instance.
    def sandbox = @sandbox ||= Rbrun.sandbox(labels: { session: id.to_s })

    # ONE turn, end to end: flip to working, run it, then land on done or (gated) needs_approval. A
    # failure flips to failed, logs an error row the agent/UI can read, and re-raises. `runtime:` is
    # an injection seam for tests (nil ⇒ the real config-resolved runtime).
    def run_turn(content, runtime: nil)
      working!
      turn = Rbrun::AgentTurn.new(session: self, runtime: runtime)
      turn.run(content)
      turn.gated? ? needs_approval! : done!
      turn
    rescue StandardError => e
      failed!
      messages.create!(role: "assistant", event_type: "error", payload: { "message" => e.message })
      raise
    end
  end
end
