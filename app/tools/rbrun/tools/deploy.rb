module Rbrun
  module Tools
    # Deploy this worktree's app to its provisioned server. The AGENT declares the intent; WE handle the
    # infra — the build+deploy runs off-turn on our build host (clone the pushed branch → Kamal local
    # builder → SSH-deploy), tracked on the target (poll deploy_status). GATED — a deploy makes the app
    # publicly reachable, a human decision (invariant #10).
    class Deploy < Rbrun::ApplicationTool
      description "Deploy this worktree's app to its provisioned server via Kamal (built on our host from the pushed branch). Requires approval; runs off-turn — poll deploy_status."
      needs_approval!

      def execute
        wt = session.worktree
        t = wt.deploy_target
        return error("no server provisioned — run provision_server first") if t.nil? || t.server_ip.blank?
        # Enforced: we deploy the PUSHED branch, so it must be committed + pushed first.
        return error("commit + push this worktree's branch before deploying") unless Rbrun::DeployRunner.branch_pushed?(wt)

        t.update!(status: "deploying")
        Rbrun::DeployJob.perform_later(wt.id)
        { "data" => { "status" => "deploying", "url" => t.url } }
      end
    end
  end
end
