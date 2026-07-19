class CreateRbrunSessionMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_session_messages do |t|
      t.references :session, null: false, foreign_key: { to_table: :rbrun_sessions }
      t.string  :role
      t.string  :event_type
      t.text    :content
      t.json    :payload, null: false, default: {}
      t.string  :tool_use_id
      t.string  :approval_status
      t.bigint  :user_message_id
      t.timestamps
    end
    add_index :rbrun_session_messages, :event_type
    add_index :rbrun_session_messages, :tool_use_id
    add_index :rbrun_session_messages, %i[session_id approval_status], where: "approval_status IS NOT NULL",
              name: "idx_rbrun_msgs_pending"
  end
end
