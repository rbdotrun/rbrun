module Rbrun
  # The SAVED definition of one of a repo's services (web, worker, redis…) — tenant + repo scoped,
  # reusable across worktrees. repo_services_start upserts these; the panel's "Restart all" reads them.
  # No live state — that lives on ServiceRun, per worktree.
  class RepoService < ApplicationRecord
    include Rbrun::Tenanted

    validates :repo, :name, :command, presence: true

    scope :for_repo, ->(repo) { where(repo: repo).order(:position) }

    # Mint the single-label preview handle once; stable thereafter (survives the start-reset).
    def ensure_preview_token!
      update!(preview_token: SecureRandom.urlsafe_base64(6)) if preview_token.blank?
      preview_token
    end

    # The live run this preview points at. The token is repo-level (stable across restarts) but a run is
    # per-worktree, so a repo with several worktrees running this service resolves to the MOST RECENTLY
    # STARTED one. (Documented limitation; strict per-worktree isolation would need a per-worktree token.)
    def live_run
      Rbrun::ServiceRun.joins(:worktree)
                       .where(rbrun_worktrees: { Rbrun.config.tenancy_key => self[Rbrun.config.tenancy_key], repo: repo })
                       .where(name: name, status: "running")
                       .order(updated_at: :desc)
                       .first
    end
  end
end
