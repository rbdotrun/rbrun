class AddSshKeysToRbrunDeployTargets < ActiveRecord::Migration[8.1]
  def change
    # The per-deployment SSH keypair WE generate + store (infra we own) — the public half is uploaded to
    # the provider and attached to the server; the private half authenticates the Kamal deploy. Not the
    # operator's key.
    add_column :rbrun_deploy_targets, :ssh_public_key,  :text
    add_column :rbrun_deploy_targets, :ssh_private_key, :text
  end
end
