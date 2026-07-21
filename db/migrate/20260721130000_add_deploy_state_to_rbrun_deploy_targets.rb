class AddDeployStateToRbrunDeployTargets < ActiveRecord::Migration[8.1]
  def change
    # So we always know WHAT'S DEPLOYED: the agent-saved tag, the git sha that shipped, and the last
    # build+deploy output (surfaced by deploy_status / deploy_logs — parity with repo_services).
    add_column :rbrun_deploy_targets, :deploy_tag,      :string
    add_column :rbrun_deploy_targets, :deployed_sha,    :string
    add_column :rbrun_deploy_targets, :last_deploy_log, :text
  end
end
