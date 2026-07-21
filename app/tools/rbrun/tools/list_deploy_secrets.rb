module Rbrun
  module Tools
    # Show the agent which app secrets are already on file for this repo — the NAMES only, NEVER the
    # values (those are encrypted and injected as Kamal secrets at deploy time). The agent cross-checks
    # this list against what the app actually reads (every `ENV[...]`, and `config/database.yml`) to see
    # what's missing, then asks the user for the gaps via `request_secrets`. Repo-scoped: secrets are
    # filled once and reused across a repo's worktrees.
    class ListDeploySecrets < Rbrun::ApplicationTool
      description "List the NAMES of app secrets already stored for this repo (values never shown). Cross-check against what the app needs (its ENV[...] reads and config/database.yml); ask the user for any missing via request_secrets. Also reports the infra env the engine injects automatically so you don't re-request it."

      # The engine injects these at deploy time (DeployRunner#kamal_env / server adapter) — the agent must
      # NOT store or re-request them; they're infra, resolved from engine config, not repo secrets.
      INFRA_INJECTED = %w[
        KAMAL_SERVER_IP KAMAL_HOST
        KAMAL_REGISTRY_SERVER KAMAL_REGISTRY_USERNAME KAMAL_REGISTRY_PASSWORD
        KAMAL_SSH_USER KAMAL_SSH_KEY_FILE
      ].freeze

      def execute
        wt = session.worktree
        stored = Rbrun::RepoSecret.where(tenant: wt.tenant, repo: wt.repo).order(:key).pluck(:key)
        { "data" => {
          "repo"            => wt.repo,
          "stored_secrets"  => stored,
          "infra_injected"  => INFRA_INJECTED,
          "note"            => "Values are never shown. Compare stored_secrets against what the app reads (every ENV[...] and config/database.yml). infra_injected is supplied by the engine at deploy time — never store or re-request those. Ask the user for any genuinely missing secret via request_secrets."
        } }
      end
    end
  end
end
