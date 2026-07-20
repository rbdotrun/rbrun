module Rbrun
  # The preview edge's DNS: ONE wildcard record for the whole domain, and the single-label host naming.
  #
  # Single label because free Universal SSL covers only the apex + first level — <token>-preview.<domain>,
  # never <token>.preview.<domain>. ONE wildcard (`*.<domain>` → preview_target) rather than a record per
  # share, so there is nothing to clean up on revocation: an unknown host simply 404s at the proxy.
  #
  # Everything here NO-OPS unless preview_domain + preview_target are configured — previews are then just
  # unavailable, never a boot failure.
  module PreviewDomain
    module_function

    def configured? = Rbrun.config.preview_domain.present? && Rbrun.config.preview_target.present?

    def host_for(token) = "#{token}-preview.#{Rbrun.config.preview_domain}"

    def wildcard = "*.#{Rbrun.config.preview_domain}"

    # Does this request host address a preview? Returns the token, or nil. Only needs the domain (the
    # target is a write-side concern), so the proxy can route even if DNS wasn't ensured.
    def token_from_host(host)
      return nil if Rbrun.config.preview_domain.blank?

      suffix = "-preview.#{Rbrun.config.preview_domain}"
      host = host.to_s.split(":").first.to_s
      return nil unless host.end_with?(suffix)

      host.delete_suffix(suffix).presence
    end

    # Upsert the one wildcard CNAME → preview_target. Idempotent; safe on every boot. No-ops when the
    # host owns the edge (Rbrun.preview_edge set) or when previews are unconfigured.
    def ensure!(dns: nil)
      return if Rbrun.preview_edge || !configured?

      dns ||= Rbrun.dns
      dns.upsert(name: wildcard, type: "CNAME", content: Rbrun.config.preview_target, proxied: true)
    end
  end
end
