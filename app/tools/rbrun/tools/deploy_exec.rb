module Rbrun
  module Tools
    # Run a shell command on this worktree's deploy server over SSH (as the non-root `deploy` user, with the
    # keypair we own). Lets the agent inspect/debug the box — check Docker, containers, logs, disk, etc.
    class DeployExec < Rbrun::ApplicationTool
      description "Run a shell command on this worktree's deploy server (over SSH, as the deploy user) to inspect or debug it — e.g. 'docker ps', 'journalctl -u ...', 'df -h'."

      parameter :command, type: "string", description: "the shell command to run on the deploy box", required: true

      def execute(command:)
        t = session.worktree.deploy_target
        return error("no server provisioned — run provision_server first") if t.nil? || t.server_ip.blank?

        out = Rbrun::DeployRunner.new(worktree: session.worktree).exec_on_box(command)
        { "data" => { "output" => out.to_s } }
      end
    end
  end
end
