require "open3"
require "tmpdir"
require "tempfile"

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

      wait_for_box! # cloud-init must finish (deploy user + Docker) before kamal SSHes in
      with_checkout do |dir, sha|
        result = server.deploy(work_dir: dir, host: @target.host, server_ip: @target.server_ip,
                               ssh_private_key: @target.ssh_private_key, env: secrets_env)
        @target.update!(
          status:          result.ok ? "deployed" : "failed",
          deployed_sha:    result.ok ? sha : @target.deployed_sha,
          deploy_tag:      sha[0, 12], # the deployed version IS the sha
          last_deploy_log: result.output.to_s) # the FULL kamal build+deploy output — never truncate the error away
        result
      end
    end

    # Logs the agent debugs with. When the deploy did NOT succeed (build/deploy failed, or still deploying),
    # the useful signal is the BUILD/deploy output (last_deploy_log) — there is no running container to tail,
    # so fetching live app logs would return nothing and hide the real error. Only once the app is actually
    # `deployed` do we fetch live container logs.
    def logs(tail: 100)
      return @target.last_deploy_log.to_s unless @target.status == "deployed" && @target.server_ip.present?

      with_checkout do |dir, _sha|
        server.app_logs(work_dir: dir, server_ip: @target.server_ip, ssh_private_key: @target.ssh_private_key, tail: tail)
      end
    end

    SSH_USER = "deploy" # matches the cloud-init user the server adapter bakes

    # SSH into the box as `deploy` and block until cloud-init has finished (the deploy user exists, Docker is
    # installed + running). Otherwise kamal's first SSH races cloud-init and fails.
    def ssh_ready?(tail: nil)
      Tempfile.create("rbrun-wait-key") do |f|
        f.write(@target.ssh_private_key.to_s)
        f.flush
        File.chmod(0o600, f.path)
        out, = Open3.capture2e("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                               "-o", "ConnectTimeout=10", "-i", f.path, "#{SSH_USER}@#{@target.server_ip}",
                               "cloud-init status --wait >/dev/null 2>&1; docker info >/dev/null 2>&1 && echo RBRUN_READY")
        out.include?("RBRUN_READY")
      end
    end

    def wait_for_box!(attempts: 40)
      attempts.times do
        return true if ssh_ready?

        sleep 10
      end
      false
    end

    # Run a command on the deploy box over SSH (as the deploy user, with our key). Powers the deploy_exec
    # tool so the agent can inspect/debug the box.
    def exec_on_box(command)
      return "" if @target.server_ip.blank?

      Tempfile.create("rbrun-exec-key") do |f|
        f.write(@target.ssh_private_key.to_s)
        f.flush
        File.chmod(0o600, f.path)
        out, = Open3.capture2e("ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                               "-o", "ConnectTimeout=15", "-i", f.path, "#{SSH_USER}@#{@target.server_ip}", command.to_s)
        out
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
