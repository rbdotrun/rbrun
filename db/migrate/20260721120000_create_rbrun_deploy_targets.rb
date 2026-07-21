class CreateRbrunDeployTargets < ActiveRecord::Migration[8.1]
  def change
    # The worktree's deployment: which server (Hetzner) the app is deployed onto and at which DNS host. ONE
    # per worktree (mirrors ServiceExposure's per-[worktree] grain) — the worktree is the key, so the unique
    # index on worktree_id enforces 1:1. Tenant is inherited from the worktree.
    create_table :rbrun_deploy_targets do |t|
      # unique index (1:1 with the worktree) rides on the reference — no separate add_index (which would
      # collide with the reference's default index name).
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees },
                              index: { unique: true }
      t.string Rbrun.config.tenancy_key, null: false
      t.string :provider,    null: false
      t.string :server_type, null: false
      t.string :region,      null: false
      t.string :image,       null: false
      t.string :host,        null: false
      t.string :server_id
      t.string :server_ip
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
  end
end
