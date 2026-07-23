module Rbrun
  module Tools
    # The deployment's logs (parity with repo_services logs): live container logs when the server is up,
    # otherwise the last build+deploy output stored on the target.
    class DeployLogs < Rbrun::ApplicationTool
      description "Show this worktree's deployment logs: live app container logs when the server is up, else the last build+deploy output."

      parameter :tail, type: "integer", description: "how many recent app log lines to fetch", required: false

      def execute(tail: 100)
        t = session.worktree.deploy_target
        return error("no deploy target — run provision_server first") if t.nil?

        # Return the FULL log — never truncate: a build error can be anywhere, and hiding it is what blinded
        # the agent before. (tail applies only to LIVE container logs, once actually deployed.)
        logs = Rbrun::DeployRunner.new(worktree: session.worktree).logs(tail:)
        { "data" => { "logs" => logs.to_s } }
      end
    end
  end
end
