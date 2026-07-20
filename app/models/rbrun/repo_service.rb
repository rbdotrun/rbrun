module Rbrun
  # The SAVED definition of one of a repo's services (web, worker, redis…) — tenant + repo scoped,
  # reusable across worktrees. repo_services_start upserts these; the panel's "Restart all" reads them.
  # No live state — that lives on ServiceRun, per worktree.
  class RepoService < ApplicationRecord
    include Rbrun::Tenanted

    validates :repo, :name, :command, presence: true

    scope :for_repo, ->(repo) { where(repo: repo).order(:position) }
  end
end
