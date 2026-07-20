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

        out = +""
        begin
          session.worktree.sandbox.session_logs_follow(run.process_session, run.cmd_id, skip: 0, timeout: 3) do |chunk|
            out << chunk
            false
          end
        rescue Rbrun::Sandbox::TimeoutError
          # bounded read — a live service never closes the stream; we return whatever accumulated.
        end
        { "data" => { "name" => name, "logs" => out.lines.last(tail.to_i.clamp(1, 5000)).join } }
      end
    end
  end
end
