class CreateRbrunTurnReports < ActiveRecord::Migration[8.1]
  # One error report per turn (keyed on the turn's lead user message).
  def change
    create_table :rbrun_turn_reports do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.references :session, null: false, foreign_key: { to_table: :rbrun_sessions }
      t.references :user_message, null: false, foreign_key: { to_table: :rbrun_session_messages }
      t.text :comment
      t.timestamps
    end
    add_index :rbrun_turn_reports, [ Rbrun.config.tenancy_key, :user_message_id ],
              unique: true, name: "idx_rbrun_turn_reports_unique"
  end
end
