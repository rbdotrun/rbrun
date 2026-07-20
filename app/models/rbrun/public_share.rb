require "securerandom"

module Rbrun
  # Level 3 of the exposure ladder: a revocable credential making ONE running service reachable by anyone
  # with the link — WITHOUT ever opening the sandbox (the provider's box-wide public switch is never used;
  # see CLAUDE.md invariant #10). rbrun's own edge (/p/:token) is what forwards, so scoping is enforced by
  # routing: a service with no share has no route and cannot surface, whatever it binds to.
  #
  # Keyed on [worktree, name] — NOT on RepoService (repo-wide, not bound to a box) and NOT on ServiceRun
  # (destroyed by every repo_services_start reset), so the link survives restarts and dies only when
  # revoked. Re-sharing after a revoke mints a NEW token, so an old link is permanently dead.
  class PublicShare < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"

    before_validation :inherit_tenant, on: :create
    before_validation :assign_token, on: :create

    validates :name, :token, presence: true

    # The live run this share points at, if any (nil when the service isn't running).
    def service_run = worktree.service_runs.find_by(name: name)

    private

    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
    def assign_token   = self.token ||= SecureRandom.urlsafe_base64(32)
  end
end
