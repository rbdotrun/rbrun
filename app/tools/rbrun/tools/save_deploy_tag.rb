module Rbrun
  module Tools
    # Record a deploy tag/version label on this worktree's deployment, so the agent (and we) can track what
    # is deployed. Surfaced by deploy_status.
    class SaveDeployTag < Rbrun::ApplicationTool
      description "Record a deploy tag/version label on this worktree's deployment, so we track what is deployed."

      parameter :tag, type: "string", description: "the deploy tag or version label to save", required: true

      def execute(tag:)
        t = session.worktree.deploy_target
        return error("no deploy target — run provision_server first") if t.nil?

        t.update!(deploy_tag: tag)
        { "data" => { "deploy_tag" => tag } }
      end
    end
  end
end
