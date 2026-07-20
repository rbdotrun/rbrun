class AddSandboxProviderToRbrunWorktrees < ActiveRecord::Migration[8.1]
  def change
    # A worktree is BOUND to the backend hosting its box. Without this the row resolves to whatever the
    # current process's ambient default happens to be — silently creating a new empty box elsewhere.
    add_column :rbrun_worktrees, :sandbox_provider, :string
  end
end
