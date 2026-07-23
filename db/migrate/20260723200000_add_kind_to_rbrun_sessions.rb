class AddKindToRbrunSessions < ActiveRecord::Migration[8.1]
  # A Session's durable identity: :user (a person's conversation) vs machine-driven kinds
  # (:skill_scenario — a self-validating run). `auto` stays the runtime lever; `kind` is "what is this".
  def change
    add_column :rbrun_sessions, :kind, :string, default: "user", null: false
    add_index  :rbrun_sessions, :kind
  end
end
