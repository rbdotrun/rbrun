require "open3"
require "tmpdir"

module Rbrun
  # Builds + deploys a worktree's app on OUR host — the build backend seam. Clones the worktree's PUSHED
  # branch (the agent prepared + committed the Kamal setup; the engine writes NO repo files) and runs the
  # server adapter's Kamal local-builder deploy with the infra env, then records deploy state on the target.
  # No config injection, no repo-prep here — that is the agent's job (rails-kamal-deployment skill).
  class DeployRunner
    def initialize(worktree:, server: nil)
      @wt = worktree
      @target = worktree.deploy_target or raise ArgumentError, "no deploy target — provision first"
      @server = server
    end

    # Is the worktree's branch committed + pushed upstream? `deploy` gates on this — we clone the pushed
    # branch, so an unpushed branch cannot be deployed. Class method so it is trivially stubbable in tests.
    def self.branch_pushed?(worktree)
      url = "https://x-access-token:#{Rbrun.config(worktree.tenant).github_pat}@github.com/#{worktree.repo}.git"
      out, status = Open3.capture2("git", "ls-remote", "--heads", url, worktree.branch)
      status.success? && !out.strip.empty?
    end

    # Clone the pushed branch → kamal deploy → record state. Returns the Rbrun::Server::DeployResult.
    def run!
      raise ArgumentError, "server not provisioned" if @target.server_ip.blank?

      with_checkout do |dir, sha|
        result = server.deploy(work_dir: dir, host: @target.host, server_ip: @target.server_ip,
                               ssh_private_key: @target.ssh_private_key, env: secrets_env)
        @target.update!(
          status:          result.ok ? "deployed" : "failed",
          deployed_sha:    result.ok ? sha : @target.deployed_sha,
          deploy_tag:      sha[0, 12], # the deployed version IS the sha
          last_deploy_log: result.output.to_s.last(20_000))
        result
      end
    end

    # Live container logs from the deployed server (re-clones for the Kamal config). Falls back to the stored
    # last deploy log when there is no server yet.
    def logs(tail: 100)
      return @target.last_deploy_log.to_s if @target.server_ip.blank?

      with_checkout do |dir, _sha|
        server.app_logs(work_dir: dir, server_ip: @target.server_ip, ssh_private_key: @target.ssh_private_key, tail: tail)
      end
    end

    private

    def server = @server ||= Rbrun.server(tenant: @wt.tenant)

    # App secrets the deploy + running container need (RAILS_MASTER_KEY, POSTGRES_PASSWORD, …), from the
    # repo's stored secrets — the same store the preview flow uses.
    def secrets_env
      Rbrun::RepoSecret.where(tenant: @wt.tenant, repo: @wt.repo).to_h { |s| [ s.key, s.value ] }
    end

    def with_checkout
      Dir.mktmpdir("rbrun-deploy-") do |dir|
        yield dir, clone_branch(dir)
      end
    end

    def clone_branch(dir)
      pat = Rbrun.config(@wt.tenant).github_pat
      url = "https://x-access-token:#{pat}@github.com/#{@wt.repo}.git"
      system("git", "clone", "--depth", "1", "--branch", @wt.branch, url, dir, exception: true)
      out, = Open3.capture2("git", "-C", dir, "rev-parse", "HEAD")
      out.strip
    end
  end
end
