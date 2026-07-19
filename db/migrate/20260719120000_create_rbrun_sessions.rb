class CreateRbrunSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_sessions do |t|
      t.string   Rbrun.config.tenancy_key, null: false   # the configurable tenant slug
      t.string   :status, null: false, default: "idle"
      t.string   :sdk_session_id
      t.datetime :archived_at
      t.timestamps
    end
    add_index :rbrun_sessions, Rbrun.config.tenancy_key
  end
end
