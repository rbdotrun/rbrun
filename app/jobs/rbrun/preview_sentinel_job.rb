module Rbrun
  # Sweeps preview-edge DNS leftovers. The per-share lifecycle is the primary mechanism (idempotent
  # expose!/unexpose!); this is the safety net for a missed revocation. Idempotent — run it as often as the
  # host schedules it (e.g. a solid_queue recurring task); it no-ops when the host owns the edge or DNS is
  # unconfigured.
  class PreviewSentinelJob < ApplicationJob
    def perform
      summary = Rbrun::PreviewSentinel.reconcile!
      removed = Array(summary[:removed])
      created = Array(summary[:created])
      return if removed.empty? && created.empty?

      Rails.logger.info("[rbrun] preview sentinel: reaped #{removed.size}, restored #{created.size}")
    end
  end
end
