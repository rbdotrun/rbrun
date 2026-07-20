module Rbrun
  module Tools
    # The debug primitive — recent output of one service, so the agent can see why it crashed/stuck.
    # Ungated read. A live server never closes its stream, so we follow with a short bounded window and
    # return the tail.
    class RepoServicesLogs < Rbrun::ApplicationTool
      description "Read the recent output (logs) of one service by name — the way to debug why it crashed or is stuck."

      parameter :name, type: "string", description: "the service name", required: true
      parameter :tail, type: "integer", description: "number of trailing lines (default 200)"

      def execute(name:, tail: 200)
        run = session.worktree.service_runs.find_by(name: name)
        return error("no such service: #{name}") unless run
        return error("service #{name} has no process handle") if run.process_session.blank? || run.cmd_id.blank?

        logs = Rbrun::ServiceSupervisor.new(worktree: session.worktree).tail(run, lines: tail.to_i)
        { "data" => { "name" => name, "logs" => logs } }
      end
    end
  end
end
