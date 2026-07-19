class CreateRbrunWorkflows < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_workflows do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :label, null: false
      t.text   :goal
      t.text   :description
      t.timestamps
    end
    add_index :rbrun_workflows, Rbrun.config.tenancy_key

    create_table :rbrun_workflow_steps do |t|
      t.references :workflow, null: false, foreign_key: { to_table: :rbrun_workflows }
      t.integer :position, null: false
      t.string  :title,    null: false
      t.timestamps
    end

    create_table :rbrun_workflow_step_completions do |t|
      t.references :session,       null: false, foreign_key: { to_table: :rbrun_sessions }
      t.references :workflow_step, null: false, foreign_key: { to_table: :rbrun_workflow_steps }
      t.references :user_message,  foreign_key: { to_table: :rbrun_session_messages }
      t.datetime :completed_at
      t.timestamps
    end
    add_index :rbrun_workflow_step_completions, [ :session_id, :workflow_step_id ],
              unique: true, name: "idx_rbrun_wsc_session_step"

    add_reference :rbrun_sessions, :workflow, foreign_key: { to_table: :rbrun_workflows }
    add_column :rbrun_sessions, :workflow_status, :string
  end
end
