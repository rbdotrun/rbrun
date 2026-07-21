module Rbrun
  module Tools
    # Point this worktree's deploy host at the provisioned server IP (A record, via the :dns family).
    class CreateDeployDns < Rbrun::ApplicationTool
      description "Create/update the DNS A record for this worktree's deploy host, pointing at the provisioned server IP."

      def execute
        t = session.worktree.deploy_target
        return error("no server provisioned yet — run provision_server first") if t.nil? || t.server_ip.blank?

        rec = Rbrun.dns(tenant: session.tenant).upsert(name: t.host, type: "A", content: t.server_ip)
        { "data" => { "host" => rec.name, "ip" => rec.content, "url" => t.url } }
      end
    end
  end
end
