class CreateRbrunMcpServers < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_mcp_servers do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string  :name,     null: false
      t.string  :transport, null: false      # stdio | http
      t.string  :auth                        # api_key | bearer | oauth | null
      t.string  :command                     # stdio
      t.json    :args,             default: []
      t.string  :url                         # http
      t.json    :env,              default: {}
      t.json    :headers,          default: {}
      t.json    :tools                       # exposed allowlist; null ⇒ all
      t.json    :tool_permissions, default: {}
      t.boolean :enabled,          null: false, default: true
      t.string  :config_digest               # hash over the config (env KEYS only) — divergence detection
      t.timestamps
    end
    add_index :rbrun_mcp_servers, [ Rbrun.config.tenancy_key, :name ], unique: true
  end
end
