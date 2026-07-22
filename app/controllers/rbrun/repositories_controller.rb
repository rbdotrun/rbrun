module Rbrun
  # The repo workspace switcher. `index` is the searchable result frame (server-side GitHub search via
  # the config PAT); `switch` sets the session-backed current_repo. No Repo table — the repo is a
  # GitHub "owner/name" string.
  class RepositoriesController < Rbrun::ApplicationController
    # Turbo frame of results. Blank q → recent repos; a query → GitHub search. Rendered as menu links
    # the repo-picker controller turns into picks. Served layout-less to frame requests so the response
    # is just the <turbo-frame id="repo_results"> (see ApplicationController#turbo_frame_request?).
    def index
      @repos = Rbrun.github_repos(current_tenant).search(query: params[:q].to_s)
      render :index, layout: !turbo_frame_request?
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
