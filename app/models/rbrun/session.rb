module Rbrun
  # ONE conversation, under a Worktree (which owns the sandbox + branch). A Session runs turns in the
  # worktree's shared sandbox; its tenant is inherited from the worktree.
  class Session < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create

    has_many :messages, -> { order(:created_at, :id) },
             class_name: "Rbrun::SessionMessage", dependent: :destroy
    has_many :commits, class_name: "Rbrun::Commit", dependent: :nullify

    enum :status,
         { idle: "idle", working: "working", needs_approval: "needs_approval", done: "done", failed: "failed" },
         default: "idle"

    # The Worktree's sandbox — one branch checkout shared by all Sessions under it.
    def sandbox = worktree.sandbox

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

    private

    def inherit_tenant = self.tenant ||= worktree&.tenant
  end
end
