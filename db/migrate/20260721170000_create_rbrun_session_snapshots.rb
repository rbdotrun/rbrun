class CreateRbrunSessionSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_session_snapshots do |t|
      # One snapshot per session — upserted each turn (unique index on the FK).
      t.references :session, null: false, foreign_key: { to_table: :rbrun_sessions },
                   index: { unique: true, name: "idx_rbrun_session_snapshots_uniq" }
      t.string :tenant, null: false
      t.binary :data, null: false   # the box's <workspace>/.claude history, tarred (minus skills)
      t.timestamps
    end
  end
end
