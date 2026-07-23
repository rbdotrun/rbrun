class AddPreferredSkillsToRbrunSessions < ActiveRecord::Migration[8.1]
  # Per-conversation skill emphasis. NOT a filter — every promoted skill still stages; this is the set
  # the agent is TOLD to prefer (a system-prompt injection). Empty = no steer.
  def change
    add_column :rbrun_sessions, :preferred_skills, :json, null: false, default: []
  end
end
