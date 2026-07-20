require "faraday"

module Rbrun
  # THE PUBLIC EDGE — the only unauthenticated endpoint in the engine (exposure ladder level 3, see
  # CLAUDE.md invariant #10).
  #
  # It reverse-proxies to EXACTLY ONE shared ServiceRun, attaching the provider preview token
  # SERVER-SIDE (that token must never reach the browser). Scoping is enforced by ROUTING: a service with
  # no PublicShare has no route here and therefore cannot surface, whatever address it binds to. The
  # sandbox itself is never made provider-public.
  class PublicPreviewsController < Rbrun::ApplicationController
    skip_before_action :require_authentication
    skip_forgery_protection
    layout false

    # Never relayed in either direction — they describe THIS connection, not the payload.
    HOP_BY_HOP = %w[connection keep-alive transfer-encoding upgrade proxy-authenticate
                    proxy-authorization te trailer content-length content-encoding].freeze

    def show
      share = Rbrun::PublicShare.find_by(token: params[:token])
      return head(:not_found) unless share # unknown OR revoked — deliberately indistinguishable

      run = share.service_run
      return head(:service_unavailable) unless run&.status_running? && run.url.present?

      relay(run)
    rescue StandardError => e
      Rails.logger.warn("[rbrun] public preview relay failed: #{e.class}: #{e.message}")
      head :bad_gateway
    end

    private

    # The upstream URL: ALWAYS this run's own url with the incoming path appended. The path can never
    # re-target another host or port.
    def upstream_for(run)
      [ run.url.to_s.chomp("/"), params[:path].presence ].compact.join("/")
    end

    def relay(run)
      upstream = connection.run_request(verb, upstream_for(run), request.raw_post.presence, forward_headers(run))

      upstream.headers.each do |key, value|
        response.headers[key] = value unless HOP_BY_HOP.include?(key.to_s.downcase)
      end
      render body: upstream.body,
             status: upstream.status,
             content_type: upstream.headers["content-type"].presence || "text/html"
    end

    def verb = request.request_method.downcase.to_sym

    # The provider preview token is attached HERE and only here — server-side, never rendered.
    def forward_headers(run)
      headers = { "x-daytona-preview-token" => run.token.to_s }
      headers["content-type"] = request.content_type if request.content_type.present?
      headers["accept"] = request.headers["Accept"] if request.headers["Accept"].present?
      headers
    end

    def connection
      @connection ||= Faraday.new(params: request.query_parameters) { |f| f.adapter :async_http }
    end
  end
end
