module Rbrun
  # A secret env value the user provided for a repo (RAILS_MASTER_KEY, a DB password, an API key). The
  # value is ENCRYPTED at rest and NEVER returned to the agent/LLM — it is injected as a Kamal secret
  # at deploy time (DeployRunner). Repo-scoped: filled once, reused across worktrees.
  class RepoSecret < ApplicationRecord
    include Rbrun::Tenanted

    encrypts :value

    validates :repo, :key, presence: true

    scope :for_repo, ->(repo) { where(repo: repo) }
  end
end
