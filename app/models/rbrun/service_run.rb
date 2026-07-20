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

    # A service is previewable when it serves an HTTP port AND the provider resolved a public URL.
    def previewable? = port.present? && url.present?

    private

    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
  end
end
