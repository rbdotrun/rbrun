class DropPreviewAndRepoServicesTables < ActiveRecord::Migration[8.1]
  # The preview-proxy + repo-services subsystem was removed (we deploy to real public URLs via Kamal
  # now). Drop its three dead tables. `rbrun_repo_secrets` — created by the same original migration —
  # stays: RepoSecrets still flow to the box as Kamal secrets at deploy time. Reversible: the blocks
  # mirror the tables' final shape so a rollback recreates them.
  def change
    drop_table :rbrun_service_runs do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string  :tenant,  null: false
      t.string  :name,    null: false
      t.string  :command, null: false
      t.integer :port
      t.string  :status,  null: false, default: "starting"
      t.integer :exit_code
      t.string  :url
      t.string  :token
      t.string  :process_session
      t.string  :cmd_id
      t.integer :log_offset, null: false, default: 0
      t.timestamps
      t.index [ :worktree_id, :name ], unique: true
    end

    drop_table :rbrun_service_exposures do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string  :tenant,        null: false
      t.string  :name,          null: false
      t.string  :preview_token
      t.boolean :previewed,     null: false, default: false
      t.boolean :shared_public, null: false, default: false
      t.string  :edge_url
      t.timestamps
      t.index [ :preview_token ], unique: true
      t.index [ :worktree_id, :name ], unique: true
    end

    drop_table :rbrun_repo_services do |t|
      t.string  :tenant,   null: false
      t.string  :repo,     null: false
      t.string  :name,     null: false
      t.string  :command,  null: false
      t.integer :port
      t.integer :position, null: false, default: 0
      t.timestamps
      t.index [ :tenant, :repo, :name ], unique: true, name: "idx_rbrun_repo_services_uniq"
    end
  end
end
