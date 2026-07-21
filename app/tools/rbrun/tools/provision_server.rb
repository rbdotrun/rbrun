module Rbrun
  module Tools
    # Find-or-create the cloud server for this worktree's deployment and record its IP on the worktree's
    # deploy target. Idempotent: the server name is worktree-derived, so re-running returns the same box
    # (invariant #11).
    class ProvisionServer < Rbrun::ApplicationTool
      description "Provision (find-or-create) the cloud server for this worktree's deployment and record its IP. Idempotent."

      def execute
        wt = session.worktree
        target = wt.deploy_target || wt.create_deploy_target!(default_attrs(wt))
        node = Rbrun.server(tenant: session.tenant).create_server(
          name: server_name(wt), type: target.server_type, region: target.region,
          image: target.image, labels: { "rbrun-worktree" => wt.id.to_s })
        target.update!(server_id: node.id.to_s, server_ip: node.ip, status: "provisioned")
        { "data" => { "server_ip" => node.ip, "status" => node.status, "host" => target.host } }
      end

      private

      def server_name(wt) = "rbrun-w#{wt.id}"

      def default_attrs(wt)
        cfg = Rbrun.config(session.tenant).server_provider
        prov = (cfg[:default] || :kamal_hetzner)
        pc = cfg[prov] || {}
        domain = Rbrun.config.preview_domain.presence || "preview.local"
        { provider: prov.to_s, server_type: pc[:server_type] || "cx23", region: pc[:region] || "fsn1",
          image: pc[:image] || "ubuntu-24.04", host: "#{server_name(wt)}.#{domain}", status: "pending" }
      end
    end
  end
end
