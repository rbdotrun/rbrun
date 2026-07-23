class AddAutoToRbrunSessions < ActiveRecord::Migration[8.1]
  # Autonomous mode: the turn's approval gate auto-approves instead of parking. Set by runs with no
  # human (scenario dogfoods), scoped to a disposable, reaped sandbox.
  def change
    add_column :rbrun_sessions, :auto, :boolean, null: false, default: false
  end
end
