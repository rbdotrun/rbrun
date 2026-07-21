module Rbrun
  module Tools
    # Scaffold the deploy setup (config/deploy.yml + a default Dockerfile) into the worktree, rendered with
    # this target's host + registry. The agent should commit + push them so the build host can build from
    # the branch. Idempotent — deploy.yml is overwritten each time; the Dockerfile is left alone if present.
    class PrepareDeploy < Rbrun::ApplicationTool
      description "Write config/deploy.yml + a Dockerfile into the worktree for Kamal deploy, then commit + push them so the build host can build from the branch."

      def execute
        t = session.worktree.deploy_target
        return error("no deploy target — run provision_server first") if t.nil?

        written = Rbrun::DeployScaffold.new(session.worktree, t).write!
        { "data" => { "written" => written, "next" => "commit + push these, then deploy" } }
      end
    end
  end
end
