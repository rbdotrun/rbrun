module Rbrun
  # Reconciles the preview EDGE (DNS) against the DB, which is the source of truth. The per-share lifecycle
  # (PreviewDomain.expose!/unexpose!) is already idempotent by construction — this only sweeps ESCAPES:
  #   • a preview record whose exposure is gone or no longer previewed (an aborted/missed revocation) → delete
  #   • a previewed exposure missing its record (an aborted/missed exposure) → recreate
  # so a hiccup that left the world out of step with the DB self-heals on the next run. Global by design:
  # the edge spans every tenant, so it queries exposures unscoped and matches records by the preview suffix.
  #
  # NO-OPS when the host owns the edge (Rbrun.preview_edge) or DNS is unconfigured. Enqueue
  # Rbrun::PreviewSentinelJob recurringly (the host owns the cadence) to run it.
  class PreviewSentinel
    def self.reconcile!(dns: nil) = new(dns: dns).reconcile!

    def initialize(dns: nil)
      @dns = dns
    end

    def reconcile!
      return { skipped: true } if Rbrun.preview_edge || !Rbrun::PreviewDomain.configured?

      dns   = @dns || Rbrun.dns
      want  = desired_hosts
      have  = dns.list(type: "CNAME", name_suffix: Rbrun::PreviewDomain.suffix)
      have_names = have.map { |r| r.name.to_s }.to_set

      orphans = have.map { |r| r.name.to_s }.reject { |name| want.include?(name) }
      orphans.each { |name| dns.remove(name: name, type: "CNAME") }

      missing = want.reject { |name| have_names.include?(name) }
      missing.each do |name|
        dns.upsert(name: name, type: "CNAME", content: Rbrun.config.preview_target, proxied: true)
      end

      { removed: orphans, created: missing }
    end

    private

    # Every host the DB says must exist: previewed exposures that carry a token, across ALL tenants.
    def desired_hosts
      Rbrun::ServiceExposure
        .where(previewed: true)
        .where.not(preview_token: [ nil, "" ])
        .pluck(:preview_token)
        .map { |token| Rbrun::PreviewDomain.host_for(token) }
        .to_set
    end
  end
end
