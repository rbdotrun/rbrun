class CreateSolidCableMessages < ActiveRecord::Migration[8.1]
  # Backs the solid_cable adapter (cross-process Turbo broadcasts). Lives on the app's primary DB —
  # the dummy is single-DB, so no separate cable connection.
  def change
    create_table :solid_cable_messages do |t|
      t.binary :channel, limit: 1024, null: false
      t.binary :payload, limit: 536_870_912, null: false
      t.datetime :created_at, null: false
      t.integer :channel_hash, limit: 8, null: false
      t.index :channel, name: "index_solid_cable_messages_on_channel"
      t.index :channel_hash, name: "index_solid_cable_messages_on_channel_hash"
      t.index :created_at, name: "index_solid_cable_messages_on_created_at"
    end
  end
end
