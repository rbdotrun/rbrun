module Rbrun
  # Conversations. The index is the tenant's worktrees grouped by repo (open one → its sessions).
  # Composing from root creates a NEW worktree for the chosen repo (bare when none) + a session + the
  # first turn. Repo is a per-chat choice from the composer, never a global scope.
  class SessionsController < Rbrun::ApplicationController
    def index
      @worktrees = Rbrun::Worktree.for_tenant(current_tenant).order(:repo, created_at: :desc)
    end

    def show
      @session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
    end

    def create
      content = params.dig(:message, :content).to_s
      return head(:bad_request) if content.blank?

      repo = params[:repo].to_s.strip.presence
      # `repo` is NOT NULL — a bare (no-repo) worktree carries repo "" (same shape SkillScenarioRun uses).
      worktree = if repo
        Rbrun::Worktree.create!(tenant: current_tenant, repo:, base: base_for(repo))
      else
        Rbrun::Worktree.create!(tenant: current_tenant, repo: "", bare: true)
      end
      session = worktree.sessions.create!
      AgentTurnJob.perform_later(session.id, content)
      redirect_to rbrun.session_path(session)
    end

    def retry
      session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
      ResumeTurnJob.perform_later(session.id)
      redirect_to rbrun.session_path(session)
    end

    private

      # The repo's default branch. The picker supplies it (already API-sourced from GithubRepos); if a
      # request arrives without it, we ask the API — both paths are authoritative. NEVER a literal guess
      # (a wrong base spins the worktree off a branch that may not exist).
      def base_for(repo)
        params[:base].to_s.strip.presence || Rbrun.github_repos(current_tenant).default_branch(repo)
      end
  end
end
