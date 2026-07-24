module Rbrun
  # The repo picker. `index` is the searchable result frame (server-side GitHub search via the config
  # PAT); its rows are client-side picks that populate the composer's RepoBadge (no global scope, no
  # Repo table — the repo is a GitHub "owner/name" string).
  class RepositoriesController < Rbrun::ApplicationController
    # Turbo frame of results. Blank q → recent repos; a query → GitHub search. Rendered as menu links
    # the repo-picker controller turns into picks. Served layout-less to frame requests so the response
    # is just the <turbo-frame id="repo_results"> (see ApplicationController#turbo_frame_request?).
    def index
      # The switcher trigger targets #modal: render the dialog shell (search box + a lazy #repo_results
      # frame). No GitHub call here — the shell paints instantly over a skeleton, the lazy frame fetches.
      return render(:dialog, layout: false) if turbo_frame_id == "modal"

      # Every other request is the results frame itself (the lazy load + each debounced search).
      # A resolver answering nil means THIS TENANT HAS NO GITHUB — a real, designed empty state, not a
      # cue to borrow another account's lister. (No seam and no configured PAT raises in GithubRepos.)
      lister = Rbrun.github_repos(current_tenant)
      @repos = lister ? lister.search(query: params[:q].to_s) : []
      render :index, layout: !turbo_frame_request?
    end
  end
end
