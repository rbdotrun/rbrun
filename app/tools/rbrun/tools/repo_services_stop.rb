module Rbrun
  module Tools
    # Stop one service (by name) or all of this worktree's services. Ungated.
    class RepoServicesStop < Rbrun::ApplicationTool
      description "Stop a running service by name, or all services in this worktree when name is omitted."

      parameter :name, type: "string", description: "the service name; omit to stop all"

      def execute(name: nil)
        Rbrun::ServiceLauncher.new(worktree: session.worktree).stop(name: name.presence)
        { "data" => { "stopped" => name.presence || "all" } }
      end
    end
  end
end
