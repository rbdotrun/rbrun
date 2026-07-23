module Rbrun
  # Runs the build+deploy off the turn (a local-builder build takes minutes). Thin — delegates to
  # DeployRunner, which records status/tag/sha/log on the target so the agent can poll deploy_status.
  class DeployJob < ApplicationJob
    def perform(worktree_id)
      worktree = Rbrun::Worktree.find(worktree_id)
      Rbrun::DeployRunner.new(worktree:).run!
    end
  end
end
