module Rbrun
  module Tools
    # Reap this worktree's deployment: destroy the server AND remove its DNS record, then mark the target
    # torn_down. Idempotent — safe to re-run (invariant #11).
    class TeardownDeploy < Rbrun::ApplicationTool
      description "Tear down this worktree's deployment: destroy the server and remove its DNS record."

      def execute
        wt = session.worktree
        t = wt.deploy_target
        return { "data" => { "torn_down" => true, "noop" => true } } if t.nil?

        Rbrun.server(tenant: session.tenant).destroy_server(name: "rbrun-w#{wt.id}")
        Rbrun.dns(tenant: session.tenant).remove(name: t.host, type: "A") if t.host.present?
        t.update!(status: "torn_down", server_id: nil, server_ip: nil)
        { "data" => { "torn_down" => true } }
      end
    end
  end
end
