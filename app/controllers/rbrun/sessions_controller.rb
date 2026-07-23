module Rbrun
  # Conversation index/create/show/retry. A Session lives under a Worktree, and a Worktree belongs to
  # the acting workspace (current_repo). The index is scoped to that repo; creating a conversation
  # finds-or-creates the repo's Worktree. No repo chosen → nothing to show / create.
  class SessionsController < Rbrun::ApplicationController
    def index
      @sessions =
        if current_repo
          Rbrun::Session.for_tenant(current_tenant)
                        .joins(:worktree).where(rbrun_worktrees: { repo: current_repo })
                        .where(kind: "user")
                        .order(created_at: :desc)
        else
          Rbrun::Session.none
        end
    end

    def show
      @session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
    end

    def create
      return redirect_to rbrun.sessions_path unless current_repo

      session = worktree_for(current_repo).sessions.create!
      redirect_to rbrun.session_path(session)
    end

    def retry
      session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
      ResumeTurnJob.perform_later(session.id)
      redirect_to rbrun.session_path(session)
    end

    private

      # The Worktree for the acting repo, created on first use. Base is the repo's default branch,
      # captured when the repo was picked (from the GitHub result); falls back to "main".
      def worktree_for(repo)
        Rbrun::Worktree.for_tenant(current_tenant)
                       .create_with(base: current_repo_base || "main")
                       .find_or_create_by!(repo:)
      end
  end
end
