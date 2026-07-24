module Rbrun
  # A worktree groups conversations for one (repo, branch). Its show page lists that worktree's user
  # conversations — machine-driven (:skill_scenario) sessions are excluded.
  class WorktreesController < Rbrun::ApplicationController
    def show
      @worktree = Rbrun::Worktree.for_tenant(current_tenant).find(params[:id])
      @sessions = @worktree.sessions.where(kind: "user").order(created_at: :desc)
    end
  end
end
