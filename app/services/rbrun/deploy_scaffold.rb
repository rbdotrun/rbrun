module Rbrun
  # Renders the Kamal deploy setup (config/deploy.yml + a default Dockerfile) into the worktree's sandbox so
  # the agent can review/commit/push them — the build host then clones the branch and builds from them. The
  # Dockerfile is only scaffolded when absent (never clobber an app's real one); the agent adapts it from the
  # preview-deploy skill's examples. deploy.yml uses the LOCAL builder and reads the server IP from the env.
  class DeployScaffold
    def initialize(worktree, target)
      @wt = worktree
      @target = target
    end

    # Write the files into the sandbox; returns the list written.
    def write!
      sb = @wt.sandbox
      sb.write("config/deploy.yml", deploy_yml)
      written = [ "config/deploy.yml" ]
      unless file_exists?(sb, "Dockerfile")
        sb.write("Dockerfile", default_dockerfile)
        written << "Dockerfile"
      end
      written
    end

    def deploy_yml
      reg = registry
      <<~YAML
        service: #{service}
        image: #{reg[:username]}/#{service}
        servers:
          web:
            - <%= ENV["KAMAL_SERVER_IP"] %>
        proxy:
          ssl: true
          host: #{@target.host}
        registry:
          server: #{reg[:server] || "docker.io"}
          username:
            - KAMAL_REGISTRY_USERNAME
          password:
            - KAMAL_REGISTRY_PASSWORD
        builder:
          arch: amd64
      YAML
    end

    private

    def service = "rbrun-w#{@wt.id}"

    def registry
      cfg  = Rbrun.config(@wt.tenant).server_provider
      cfg.dig(cfg[:default], :registry) || {}
    end

    def file_exists?(sb, path)
      sb.exec("test -f #{path} && echo yes").stdout.to_s.include?("yes")
    rescue StandardError
      false
    end

    def default_dockerfile
      <<~DOCKER
        # Scaffolded by rbrun preview-deploy — adapt to your app (see the preview-deploy skill examples).
        FROM ruby:3.4-slim
        WORKDIR /app
        COPY . .
        RUN bundle install --without development test || true
        EXPOSE 3000
        CMD ["bash", "-lc", "bundle exec rails server -b 0.0.0.0 -p 3000"]
      DOCKER
    end
  end
end
