module Rbrun
  # Conversation index/create/show/retry. A Session lives under a Worktree; for the built-in UI a
  # default Worktree per tenant is used (real hosts create worktrees against their own repos).
  class SessionsController < Rbrun::ApplicationController
    def index
      @sessions = Rbrun::Session.for_tenant(current_tenant).order(created_at: :desc)
    end

    def show
      @session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
    end

    def create
      session = default_worktree.sessions.create!
      redirect_to rbrun.session_path(session)
    end

    def retry
      session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
      ResumeTurnJob.perform_later(session.id)
      redirect_to rbrun.session_path(session)
    end

    private

    def default_worktree
      Rbrun::Worktree.for_tenant(current_tenant).order(:id).first ||
        Rbrun::Worktree.create!(tenant: current_tenant,
                                repo: ENV["RBRUN_WORKTREE_REPO"].presence || "rbdotrun/scratch", base: "main")
    end
  end
end
