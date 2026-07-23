class AddBareToRbrunWorktrees < ActiveRecord::Migration[8.1]
  # A bare worktree has no repo to clone — its box is just a scratch workspace (skill authoring,
  # scenario dogfoods). A normal worktree clones its repo into a checkout subdir of the workspace.
  def change
    add_column :rbrun_worktrees, :bare, :boolean, null: false, default: false
  end
end
