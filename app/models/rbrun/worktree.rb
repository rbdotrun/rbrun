require "securerandom"

module Rbrun
  # rbrun's unit of work (NOT a git worktree): one git branch + one sandbox, shared by all the
  # Sessions under it. The branch is spun off `base` in `repo`; the agent commits + pushes to it via
  # its git tools during turns.
  class Worktree < ApplicationRecord
    include Rbrun::Tenanted

    has_many :sessions, class_name: "Rbrun::Session", dependent: :destroy
    has_many :commits,  class_name: "Rbrun::Commit",  dependent: :destroy
    has_many :service_runs, class_name: "Rbrun::ServiceRun", dependent: :destroy

    before_validation :assign_branch, on: :create

    # The branch's checkout, shared by every Session under this Worktree. Addressed by the worktree id.
    def sandbox = @sandbox ||= Rbrun.sandbox(tenant: tenant, labels: { worktree: id.to_s })

    # Preview capability probe (no registry): true when this worktree's sandbox provider can publish a
    # port. The UI gates the Open ↗ affordance on this; the launcher gates preview resolution on it.
    def previews_supported? = sandbox.respond_to?(:preview_url)

    # Clone the repo into the sandbox and spin the branch off base — using the config github_pat. Run
    # once, when the worktree is first used.
    def provision!
      sandbox.exec!(provision_command, timeout: 300)
      self
    end

    def provision_command
      pat = Rbrun.config(tenant).github_pat
      url = "https://x-access-token:#{pat}@github.com/#{repo}.git"
      ws  = sandbox.workspace
      <<~SH.strip
        cd #{ws} && \
        (git rev-parse --git-dir >/dev/null 2>&1 || (git clone #{url} . && git remote set-url origin #{url})) && \
        git fetch origin #{base} && git checkout #{base} && git checkout -B #{branch} && \
        git push -u origin #{branch}
      SH
    end

    # The branch HEAD in the sandbox, or nil for a non-git sandbox (unit tests) — guarded, never raises.
    def head_sha
      r = sandbox.exec("cd #{sandbox.workspace} && git rev-parse HEAD 2>/dev/null")
      r.success? ? r.stdout.strip : nil
    end

    private

    def assign_branch = self.branch ||= "rbrun/wt-#{SecureRandom.hex(4)}"
  end
end
