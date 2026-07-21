require "open3"
require "tmpdir"
require "fileutils"

module Rbrun
  # Builds + deploys a worktree's app on OUR host — the build backend seam. Clones the worktree's pushed
  # branch (code comes from git, NOT the sandbox — no Daytona DinD lock-in, WE own the Docker cache), injects
  # OUR Kamal deploy config (our box, our registry, Let's Encrypt, a colocated Postgres accessory — the
  # deploy config is our infra, never committed to the app's repo), runs the adapter's Kamal local-builder
  # deploy, and records deploy state on the target. Idempotent per target — re-running redeploys.
  class DeployRunner
    def initialize(worktree:, server: nil)
      @wt = worktree
      @target = worktree.deploy_target or raise ArgumentError, "no deploy target — provision first"
      @server = server
    end

    # Clone → inject config → kamal deploy → record state. Returns the Rbrun::Server::DeployResult.
    def run!
      raise ArgumentError, "server not provisioned" if @target.server_ip.blank?

      with_checkout do |dir, sha|
        render_deploy_config!(dir)
        result = server.deploy(work_dir: dir, host: @target.host, server_ip: @target.server_ip,
                               ssh_private_key: @target.ssh_private_key, env: secrets_env)
        @target.update!(
          status:          result.ok ? "deployed" : "failed",
          deployed_sha:    result.ok ? sha : @target.deployed_sha,
          deploy_tag:      @target.deploy_tag.presence || sha[0, 12],
          last_deploy_log: result.output.to_s.last(20_000))
        result
      end
    end

    # Live container logs from the deployed server (re-clones + re-injects config for the Kamal run). Falls
    # back to the stored last deploy log when there is no server yet.
    def logs(tail: 100)
      return @target.last_deploy_log.to_s if @target.server_ip.blank?

      with_checkout do |dir, _sha|
        render_deploy_config!(dir)
        server.app_logs(work_dir: dir, server_ip: @target.server_ip, ssh_private_key: @target.ssh_private_key, tail: tail)
      end
    end

    private

    def service = "rbrun-w#{@wt.id}"

    def server = @server ||= Rbrun.server(tenant: @wt.tenant)

    def registry
      cfg = Rbrun.config(@wt.tenant).server_provider
      cfg.dig(cfg[:default], :registry) || {}
    end

    # App secrets (RAILS_MASTER_KEY, POSTGRES_PASSWORD, …) the running container + the deploy need — sourced
    # from the repo's stored secrets (same store the preview flow uses).
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

    # Write OUR config over the clone: single box, our registry, Let's Encrypt TLS, a colocated Postgres
    # accessory. The app only needs a Dockerfile — the deploy config is ours (invariant: we own the infra).
    def render_deploy_config!(dir)
      reg = registry
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "deploy.yml"), deploy_yml(reg))
      FileUtils.mkdir_p(File.join(dir, ".kamal"))
      File.write(File.join(dir, ".kamal", "secrets"), kamal_secrets)
    end

    def deploy_yml(reg)
      <<~YAML
        service: #{service}
        image: #{reg[:username]}/#{service}
        servers:
          web:
            - #{@target.server_ip}
        proxy:
          ssl: true
          host: #{@target.host}
          app_port: 80
          healthcheck:
            path: /up
        registry:
          server: #{reg[:server] || "docker.io"}
          username:
            - KAMAL_REGISTRY_USERNAME
          password:
            - KAMAL_REGISTRY_PASSWORD
        env:
          clear:
            RAILS_ENV: production
            RAILS_LOG_TO_STDOUT: "1"
            POSTGRES_HOST: #{service}-db
            POSTGRES_USER: app
            POSTGRES_DB: app_production
            POSTGRES_PORT: "5432"
          secret:
            - RAILS_MASTER_KEY
            - POSTGRES_PASSWORD
        accessories:
          db:
            image: postgres:16
            host: #{@target.server_ip}
            env:
              clear:
                POSTGRES_USER: app
                POSTGRES_DB: app_production
              secret:
                - POSTGRES_PASSWORD
            directories:
              - data:/var/lib/postgresql/data
        ssh:
          user: root
          keys:
            - <%= ENV["KAMAL_SSH_KEY_FILE"] %>
        builder:
          arch: amd64
      YAML
    end

    def kamal_secrets
      <<~SECRETS
        KAMAL_REGISTRY_USERNAME=$KAMAL_REGISTRY_USERNAME
        KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
        RAILS_MASTER_KEY=$RAILS_MASTER_KEY
        POSTGRES_PASSWORD=$POSTGRES_PASSWORD
      SECRETS
    end
  end
end
