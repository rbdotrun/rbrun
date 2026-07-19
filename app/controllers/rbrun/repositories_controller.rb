module Rbrun
  # The repo workspace switcher. `index` is the searchable result frame (server-side GitHub search via
  # the config PAT); `switch` sets the session-backed current_repo. No Repo table — the repo is a
  # GitHub "owner/name" string.
  class RepositoriesController < Rbrun::ApplicationController
    # Turbo frame of results. Blank q → recent repos; a query → GitHub search. Rendered as menu links
    # the command controller turns into picks.
    def index
      @repos = Rbrun.github_repos(current_tenant).search(query: params[:q].to_s)
    end

    # Set the acting workspace (+ its default branch, for worktree base) and return to its index.
    def switch
      repo = params[:repo].to_s.strip
      session[:rbrun_repo]      = repo.presence
      session[:rbrun_repo_base] = (repo.present? ? params[:base].to_s.presence : nil)
      redirect_to rbrun.sessions_path
    end
  end
end
