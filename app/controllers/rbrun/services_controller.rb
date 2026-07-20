module Rbrun
  # Operate the current worktree's running services from the sidebar panel. Control actions delegate to
  # ServiceLauncher (whose DB writes trigger the panel broadcast); `open` sends the browser to the live
  # app; `logs` opens the drawer with a bounded tail. All tenant-scoped to the viewer.
  class ServicesController < Rbrun::ApplicationController
    before_action :set_run, only: %i[open logs restart stop]

    # Send the browser to the live app. VERIFIED against Daytona: the preview token is HEADER-ONLY
    # (x-daytona-preview-token → 200), which a browser tab can never send. Passing it as a query param
    # does NOT authenticate — the proxy 307s to its own login and the token is ignored. So we redirect to
    # the bare URL and let the proxy authenticate the viewer's own provider session.
    def open
      return head(:not_found) unless @run.previewable?

      redirect_to @run.url, allow_other_host: true
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
  end
end
