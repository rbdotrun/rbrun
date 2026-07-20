module Rbrun
  # A live running service in ONE worktree's sandbox — the run layer. Holds the managed-process handle
  # (process_session + cmd_id, pidfile-stoppable) and, for an HTTP service, its resolved preview
  # (url + token). Command/port are snapshotted at launch, so a run is self-contained.
  class ServiceRun < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create

    enum :status, { starting: "starting", running: "running", exited: "exited", stopped: "stopped" },
         prefix: :status

    validates :name, :command, presence: true

    after_create_commit  :broadcast_panel
    after_update_commit  :broadcast_panel
    after_destroy_commit :broadcast_panel

    # A service is previewable when it serves an HTTP port AND the provider resolved a public URL.
    def previewable? = port.present? && url.present?

    # Repaint the whole worktree Services panel (its own worktree stream, seen by every session's
    # sidebar). Rendered from DB rows only — no sandbox calls, so a broadcast is always safe.
    def broadcast_panel
      ::Turbo::StreamsChannel.broadcast_replace_to("rbrun_worktree_#{worktree_id}",
        target: "services_panel_#{worktree_id}",
        partial: "rbrun/services/panel", locals: { worktree: worktree })
    end

    private

    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
  end
end
