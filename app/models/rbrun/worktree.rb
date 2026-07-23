require "securerandom"

module Rbrun
  # rbrun's unit of work (NOT a git worktree): one git branch + one sandbox, shared by all the
  # Sessions under it. The branch is spun off `base` in `repo`; the agent commits + pushes to it via
  # its git tools during turns.
  class Worktree < ApplicationRecord
    # Raised when a worktree can't be provisioned (no repo to clone) — loud, never swallowed.
    class Error < StandardError; end

    include Rbrun::Tenanted

    has_many :sessions, class_name: "Rbrun::Session", dependent: :destroy
    has_many :commits,  class_name: "Rbrun::Commit",  dependent: :destroy
    has_one  :deploy_target, class_name: "Rbrun::DeployTarget", dependent: :destroy

    before_validation :assign_branch, on: :create
    before_validation :assign_sandbox_provider, on: :create

    # The branch's checkout, shared by every Session under this Worktree. Addressed by the worktree id.
    #
    # The PROVIDER IS PERSISTED (sandbox_provider), not taken from the ambient process config: a worktree
    # is bound to the backend hosting its box, so loading this row in ANY process (web, job, rake, runner)
    # resolves the SAME box. Without it the row silently resolved to whatever that process defaulted to —
    # quietly creating a new empty box instead of finding the real one. If the process can't build that
    # provider (missing credentials), this now fails LOUDLY rather than drifting to another backend.
    def sandbox = @sandbox ||= Rbrun.sandbox(sandbox_provider&.to_sym, tenant: tenant, labels: { worktree: id.to_s })

    # The agent's working directory inside the box. A normal worktree clones its repo into a SUBDIR of
    # the workspace (so the checkout sits SIDE BY SIDE with the sibling .claude/, never colliding with
    # it) and the agent works there. A bare worktree (skills/scenarios) has no repo — cwd is the
    # workspace itself. `.claude/` always lives at <workspace>/.claude regardless.
    def checkout = bare? ? sandbox.workspace : File.join(sandbox.workspace, File.basename(repo.to_s))

    def archived? = archived_at.present?

    # The ONE teardown entry point. Soft-deletes the worktree but GUARANTEES its remote resources are gone
    # first — the dev sandbox, and (if it was deployed) its server + DNS record. So callers never hand-reap
    # infra: reaping is a property of archiving a worktree. Idempotent — safe to re-run.
    def archive!
      begin
        sandbox.destroy!
      rescue StandardError
        nil
      end
      if (target = deploy_target)
        server_name = "rbrun-w#{id}"
        begin
          Rbrun.server(tenant: tenant).destroy_server(name: server_name)
        rescue StandardError
          nil
        end
        begin
          Rbrun.dns(tenant: tenant).remove(name: target.host, type: "A") if target.host.present?
        rescue StandardError
          nil
        end
      end
      update!(archived_at: Time.current)
      self
    end

    # Clone the repo into the checkout subdir and spin the branch off base — using the config
    # github_pat. Idempotent (skips the clone when the checkout already has a repo) and box-loss-safe.
    # RAISES on failure — a conversation whose repo could not be provisioned is broken, and the caller
    # (and the UI) must know, not silently run in an empty box. A bare worktree has nothing to clone.
    def provision!
      return self if bare?
      raise Error, "worktree ##{id} has no repo to provision" if repo.blank?

      sandbox.exec!(provision_command, timeout: 300)
      self
    end

    def provision_command
      pat = Rbrun.config(tenant).github_pat
      url = "https://x-access-token:#{pat}@github.com/#{repo}.git"
      dir = checkout
      # Clone with a token-embedded URL (for the initial fetch), then hand auth to gh: `gh auth
      # login --with-token` stores the token in gh's own keyring and `gh auth setup-git` makes git use
      # it — so the agent's Bash (which does NOT inherit the run env) has working git AND gh without
      # ever handling the token itself. Reset origin to a CLEAN url so the token isn't left in
      # .git/config. Then DERIVE the git identity from the token's own GitHub user (best-effort — a
      # `{ …; true; }` group so a failure can't break the chain; the image's baked identity is the
      # fallback), so commits are attributed to whoever the PAT belongs to, not a generic bot.
      <<~SH.strip
        mkdir -p #{dir} && cd #{dir} && \
        (git rev-parse --git-dir >/dev/null 2>&1 || git clone #{url} .) && \
        git fetch origin #{base} && git checkout #{base} && git checkout -B #{branch} && \
        printf '%s' "#{pat}" | gh auth login --with-token && gh auth setup-git && \
        git remote set-url origin https://github.com/#{repo}.git && \
        { u=$(gh api user --jq .login 2>/dev/null); \
          e=$(gh api user --jq '.email // ((.id|tostring) + "+" + .login + "@users.noreply.github.com")' 2>/dev/null); \
          [ -n "$u" ] && git config user.name "$u"; \
          [ -n "$e" ] && git config user.email "$e"; true; } && \
        git push -u origin #{branch}
      SH
    end

    # The branch HEAD in the checkout, or nil for a non-git checkout (fresh/bare box) — guarded, never
    # raises. nil is the signal that provisioning is needed (or that the box was lost and reset).
    def head_sha
      r = sandbox.exec("cd #{checkout} && git rev-parse HEAD 2>/dev/null")
      r.success? ? r.stdout.strip : nil
    end

    private

    def assign_branch = self.branch ||= "rbrun/wt-#{SecureRandom.hex(4)}"

    # Record the backend this worktree's box is created on, so every later process resolves the same one.
    def assign_sandbox_provider
      self.sandbox_provider ||= Rbrun.config(tenant).sandbox_provider[:default]&.to_s
    end
  end
end
