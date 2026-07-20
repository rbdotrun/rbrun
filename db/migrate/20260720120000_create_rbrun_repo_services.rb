class CreateRbrunRepoServices < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_repo_services do |t|
      t.string  Rbrun.config.tenancy_key, null: false
      t.string  :repo,     null: false
      t.string  :name,     null: false
      t.string  :command,  null: false
      t.integer :port
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :rbrun_repo_services, [ Rbrun.config.tenancy_key, :repo, :name ],
              unique: true, name: "idx_rbrun_repo_services_uniq"

    create_table :rbrun_service_runs do |t|
      t.references :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
      t.string  Rbrun.config.tenancy_key, null: false
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
    end
    add_index :rbrun_service_runs, [ :worktree_id, :name ], unique: true

    create_table :rbrun_repo_secrets do |t|
      t.string :tenant, null: false
      t.string :repo,   null: false
      t.string :key,    null: false
      t.text   :value
      t.timestamps
    end
    add_index :rbrun_repo_secrets, [ :tenant, :repo, :key ], unique: true, name: "idx_rbrun_repo_secrets_uniq"
  end
end
