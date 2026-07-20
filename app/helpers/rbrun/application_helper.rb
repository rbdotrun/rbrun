module Rbrun
  module ApplicationHelper
    # The worktree in context — the current conversation's worktree. Worktree-scoped UI (the Services
    # panel) renders for this; absent on pages without a conversation (index, skills…). Mirrors the
    # current_repo seam.
    def current_worktree = @session&.worktree
  end
end
