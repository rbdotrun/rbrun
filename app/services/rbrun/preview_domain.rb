module Rbrun
  # The preview edge's DNS: ONE record PER SHARED PREVIEW, created on expose and deleted on stop. Single
  # label because free Universal SSL covers only the apex + first level (<token>-preview.<domain>, never
  # <token>.preview.<domain>). A wildcard CNAME does not route through a Cloudflare tunnel, so each host
  # gets its own record; revocation is then a real deletion, not a dangling wildcard.
  #
  # Everything here NO-OPS unless preview_domain + preview_target are configured, or when the host owns the
  # edge (Rbrun.preview_edge). Best-effort: a DNS hiccup logs and continues — a Sentinel reconciles leaks.
  module PreviewDomain
    module_function

    def configured? = Rbrun.config.preview_domain.present? && Rbrun.config.preview_target.present?

    def host_for(token) = "#{token}-preview.#{Rbrun.config.preview_domain}"

    def suffix = "-preview.#{Rbrun.config.preview_domain}"

    # Does this request host address a preview? Returns the token, or nil. Only needs the domain.
    def token_from_host(host)
      return nil if Rbrun.config.preview_domain.blank?

      host = host.to_s.split(":").first.to_s
      return nil unless host.end_with?(suffix)

      host.delete_suffix(suffix).presence
    end

    # Create the one record for this preview host → preview_target. Idempotent (upsert).
    def expose!(token, dns: nil)
      return if Rbrun.preview_edge || !configured? || token.blank?

      (dns || Rbrun.dns).upsert(name: host_for(token), type: "CNAME", content: Rbrun.config.preview_target, proxied: true)
    rescue StandardError => e
      Rails.logger.warn("[rbrun] preview DNS expose(#{token}) failed: #{e.message} — the Sentinel will retry")
    end

    # Delete this preview host's record. Idempotent (a missing record is a no-op in the adapter).
    def unexpose!(token, dns: nil)
      return if Rbrun.preview_edge || !configured? || token.blank?

      (dns || Rbrun.dns).remove(name: host_for(token), type: "CNAME")
    rescue StandardError => e
      Rails.logger.warn("[rbrun] preview DNS unexpose(#{token}) failed: #{e.message} — the Sentinel will reap")
    end
  end
end
