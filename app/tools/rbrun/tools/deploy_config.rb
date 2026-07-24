module Rbrun
  module Tools
    # Hand the agent the EXACT infra values for config/deploy.yml that live in engine config, not the repo —
    # so it never guesses: the container registry + fully-qualified image, and the SSH access (the box runs a
    # non-root `deploy` user; the private key is injected at deploy time via KAMAL_SSH_KEY_FILE). Put these
    # literal values in deploy.yml; the `ssh:` block is REQUIRED (kamal defaults to root, which is disabled).
    class DeployConfig < Rbrun::ApplicationTool
      description "Get the exact deploy.yml infra values: registry server/username, the fully-qualified image, and the SSH block (user: deploy + key). Use them literally — never a bare image, and always include the ssh block."

      def execute
        cfg = Rbrun.config(session.tenant).server_provider
        # This tool exists so the agent never guesses — so it must not guess either. Two absences used
        # to collapse into the same `{}` and then into "docker.io" + a blank username: (a) no server
        # provider configured at all, and (b) a provider with no registry block. The agent then wrote
        # docker.io into deploy.yml and kamal pushed to Docker Hub with (say) GHCR credentials, failing
        # deep in the build with an error that points at nothing. Report the missing config instead.
        prov = cfg[:default]
        return error("no server provider configured — set c.server_provider[:default]") if prov.blank?

        reg = cfg.dig(prov, :registry)
        if reg.blank? || reg[:server].blank? || reg[:username].blank?
          return error("no container registry configured — set " \
                       "c.server_provider[:#{prov}][:registry] = { server:, username:, password: }")
        end

        service = "rbrun-w#{session.worktree.id}"
        { "data" => {
          "registry_server"   => reg[:server].to_s,
          "registry_username" => reg[:username].to_s,
          "service"           => service,
          "image"             => "#{reg[:username]}/#{service}",
          "ssh_user"          => "deploy",
          "ssh_note"          => "The box has NO root login and NO password auth — SSH in as `deploy`. The private key is injected at deploy time via KAMAL_SSH_KEY_FILE.",
          "deploy_yml_ssh"    => "ssh:\n  user: deploy\n  keys:\n    - <%= ENV[\"KAMAL_SSH_KEY_FILE\"] %>"
        } }
      end
    end
  end
end
