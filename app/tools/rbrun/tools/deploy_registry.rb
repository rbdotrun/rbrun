module Rbrun
  module Tools
    # Hand the agent the EXACT container registry + fully-qualified image name for config/deploy.yml. The
    # registry namespace lives in engine config (not the repo), so the agent must NOT guess it — a bare image
    # name like `dummy-rails` is rejected by the registry. Use these values literally.
    class DeployRegistry < Rbrun::ApplicationTool
      description "Get the exact container registry server, username, and fully-qualified image name for config/deploy.yml. Put these literal values in the file — never guess the registry namespace or use a bare image name."

      def execute
        cfg = Rbrun.config(session.tenant).server_provider
        reg = cfg.dig(cfg[:default], :registry) || {}
        service = "rbrun-w#{session.worktree.id}"
        { "data" => { "registry_server" => (reg[:server].presence || "docker.io"),
                      "registry_username" => reg[:username].to_s,
                      "service" => service,
                      "image" => "#{reg[:username]}/#{service}" } }
      end
    end
  end
end
