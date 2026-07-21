require "open3"
require "tmpdir"

module Rbrun
  # Builds + deploys a worktree's app on OUR host — the build backend seam. Clones the worktree's pushed
  # branch (code comes from git, NOT the sandbox — so no Daytona DinD lock-in and WE own the Docker cache),
  # runs the server adapter's Kamal local-builder deploy, and records deploy state on the target. A dedicated
  # or remote build backend can replace this class without touching the agent or the adapter. Idempotent per
  # target — re-running redeploys.
  class DeployRunner
    def initialize(worktree:, server: nil)
      @wt = worktree
      @target = worktree.deploy_target or raise ArgumentError, "no deploy target — provision first"
      @server = server
    end

    # Clone → kamal deploy → record state. Returns the Rbrun::Server::DeployResult.
    def run!
      raise ArgumentError, "server not provisioned" if @target.server_ip.blank?

      with_checkout do |dir, sha|
        result = server.deploy(work_dir: dir, host: @target.host, server_ip: @target.server_ip)
        @target.update!(
          status:          result.ok ? "deployed" : "failed",
          deployed_sha:    result.ok ? sha : @target.deployed_sha,
          deploy_tag:      @target.deploy_tag.presence || sha[0, 12],
          last_deploy_log: result.output.to_s.last(20_000))
        result
      end
    end

    # Live container logs from the deployed server (re-clones for the Kamal config). Falls back to the stored
    # last deploy log when there is no server yet.
    def logs(tail: 100)
      return @target.last_deploy_log.to_s if @target.server_ip.blank?

      with_checkout { |dir, _sha| server.app_logs(work_dir: dir, server_ip: @target.server_ip, tail: tail) }
    end

    private

    def server = @server ||= Rbrun.server(tenant: @wt.tenant)

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
