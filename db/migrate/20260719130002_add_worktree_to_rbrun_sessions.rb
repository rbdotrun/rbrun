class AddWorktreeToRbrunSessions < ActiveRecord::Migration[8.1]
  def change
    add_reference :rbrun_sessions, :worktree, null: false, foreign_key: { to_table: :rbrun_worktrees }
  end
end
