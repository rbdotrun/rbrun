module Rbrun
  module Tools
    # Restart ONE stuck service — kill it and start it again from its saved command. Ungated (control on
    # an already-approved service). Idempotent.
    class RepoServicesRestart < Rbrun::ApplicationTool
      description "Restart one running service by name (kill + start again from its command). Use when a service is stuck."

      parameter :name, type: "string", description: "the service name", required: true

      def execute(name:)
        run = Rbrun::ServiceLauncher.new(worktree: session.worktree).restart(name)
        return error("no such service: #{name}") unless run

        { "data" => { "name" => run.name, "status" => run.status, "url" => run.url } }
      end
    end
  end
end
