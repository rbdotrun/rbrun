module Rbrun
  module Tools
    # What's running now, and its state — so the agent knows what's up / exited / stuck (the same truth
    # rbrun renders). Ungated read.
    class RepoServicesStatus < Rbrun::ApplicationTool
      description "List this worktree's services and their current status (running / exited / stopped), with the preview URL for HTTP services."

      def execute
        services = Rbrun::ServiceLauncher.new(worktree: session.worktree).status.map do |r|
          { "name" => r.name, "command" => r.command, "port" => r.port, "status" => r.status, "url" => r.url }
        end
        { "data" => { "services" => services } }
      end
    end
  end
end
