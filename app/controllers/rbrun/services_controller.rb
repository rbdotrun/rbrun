module Rbrun
  # Operate the current worktree's running services from the sidebar panel. Control actions delegate to
  # ServiceLauncher (whose DB writes trigger the panel broadcast); `open` is the token seam to the live
  # app; `logs` opens the drawer with a bounded tail. All tenant-scoped to the viewer.
  class ServicesController < Rbrun::ApplicationController
    before_action :set_run, only: %i[open logs restart stop]

    # The token seam: turn the stored (url, token) into a browser-openable request. For a public /
    # localhost port there is no token; a private Daytona port's mechanism is verified in the dogfood and
    # adapted HERE only. Opens in a new tab (the panel link carries target=_blank).
    def open
      return head(:not_found) unless @run.previewable?

      redirect_to preview_target(@run), allow_other_host: true
    end

    def logs
      tail = Rbrun::ServiceSupervisor.new(worktree: @run.worktree).tail(@run, lines: 300)
      render turbo_stream: turbo_stream.replace("service_drawer",
        partial: "rbrun/services/logs_drawer", locals: { run: @run, logs: tail })
    end

    def restart
      launcher.restart(@run.name)
      head :no_content
    end

    def stop
      launcher.stop(name: @run.name)
      head :no_content
    end

    def restart_all
      worktree = worktrees.find(params[:worktree_id])
      Rbrun::ServiceLauncher.new(worktree: worktree).restart_saved
      head :no_content
    end

    private

    def worktrees = Rbrun::Worktree.for_tenant(current_tenant)
    def set_run   = @run = Rbrun::ServiceRun.for_tenant(current_tenant).find(params[:id])
    def launcher  = Rbrun::ServiceLauncher.new(worktree: @run.worktree)

    # The URL to hand the browser. If the provider returned a token (private port), append it the way its
    # proxy accepts — VERIFIED in the preview_daytona dogfood, adapted here only. Localhost/public: as-is.
    def preview_target(run)
      return run.url if run.token.blank?

      sep = run.url.include?("?") ? "&" : "?"
      "#{run.url}#{sep}token=#{CGI.escape(run.token)}"
    end
  end
end
