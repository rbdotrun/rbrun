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
  end
end
