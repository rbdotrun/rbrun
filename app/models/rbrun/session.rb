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
      before = worktree.head_sha
      turn = Rbrun::AgentTurn.new(session: self, runtime: runtime)
      turn.run(content)
      record_commits!(before)
      turn.gated? ? needs_approval! : done!
      turn
    rescue StandardError => e
      failed!
      messages.create!(role: "assistant", event_type: "error", payload: { "message" => e.message })
      raise
    end

    private

    def inherit_tenant = self.tenant ||= worktree&.tenant

    # Read the commits the agent pushed during the turn (HEAD before → after) and record them.
    # Guarded: a non-git sandbox (unit tests, un-provisioned worktrees) records nothing.
    def record_commits!(before)
      after = worktree.head_sha
      return if after.nil? || after == before

      range = before ? "#{before}..#{after}" : after
      out = worktree.sandbox.exec("cd #{worktree.sandbox.workspace} && git log --format='%H%x09%s' #{range} 2>/dev/null")
      return unless out.success?

      out.stdout.each_line do |line|
        sha, message = line.strip.split("\t", 2)
        next if sha.to_s.empty?

        worktree.commits.find_or_create_by!(sha: sha) { |c| c.session = self; c.message = message }
      end
    end
  end
end
