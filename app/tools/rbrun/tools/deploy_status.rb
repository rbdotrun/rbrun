module Rbrun
  module Tools
    # Read-only: this worktree's deployment — the live URL, lifecycle status, deploy tag, shipped git sha,
    # and server IP. So the agent (and we) always know what's up.
    class DeployStatus < Rbrun::ApplicationTool
      description "Show this worktree's deployment: live URL, status, deploy tag, shipped git sha, and server IP."

      def execute
        t = session.worktree.deploy_target
        return { "data" => { "status" => "none" } } if t.nil?

        { "data" => { "status" => t.status, "url" => t.url, "host" => t.host, "server_ip" => t.server_ip,
                      "deploy_tag" => t.deploy_tag, "deployed_sha" => t.deployed_sha } }
      end
    end
  end
end
