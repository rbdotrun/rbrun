class AddArchivedAtToRbrunWorktrees < ActiveRecord::Migration[8.1]
  def change
    add_column :rbrun_worktrees, :archived_at, :datetime
  end
end
