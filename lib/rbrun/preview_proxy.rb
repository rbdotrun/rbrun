# frozen_string_literal: true

require "faraday"
require "async/http/faraday"

module Rbrun
  # THE PREVIEW EDGE — the engine's own proxy (no Cloudflare Worker). Rack middleware that intercepts
  # requests whose Host is a preview host (<token>-preview.<domain>) and reverse-proxies to exactly one
  # running service inside its sandbox, attaching the provider preview token SERVER-SIDE (never to the
  # browser). Everything else passes straight through.
  #
  # Scoping is enforced by ROUTING: a service with no preview_token has no host, and an unshared, private
  # service demands an rbrun session. The sandbox is never made provider-public.
  #
  # No-ops entirely when the host app owns the edge (Rbrun.preview_edge set) — the control plane's own
  # edge serves the data path then.
  class PreviewProxy
    HOP_BY_HOP = %w[connection keep-alive transfer-encoding upgrade proxy-authenticate
                    proxy-authorization te trailer content-length content-encoding].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if Rbrun.preview_edge

      request = ActionDispatch::Request.new(env)
      token = Rbrun::PreviewDomain.token_from_host(request.host)
      return @app.call(env) unless token

      serve(request, token)
    rescue StandardError => e
      Rails.logger.warn("[rbrun] preview proxy failed: #{e.class}: #{e.message}")
      [ 502, { "content-type" => "text/plain" }, [ "Preview unavailable." ] ]
    end

    private

    def serve(request, token)
      service = Rbrun::RepoService.find_by(preview_token: token)
      return not_found unless service

      run = service.live_run
      return unavailable unless run&.url.present?

      # Level gate. Public ⇒ anyone. Private ⇒ an rbrun session is required (a teammate needs an rbrun
      # account, not a Daytona one). NOTE: for the private path across subdomains, the session cookie must
      # be scoped to ".<domain>" — otherwise the preview host never sees it. Public needs no session.
      return require_login unless service.shared_public? || authenticated?(request)

      relay(request, run)
    end

    def authenticated?(request)
      session = request.session
      Rbrun.current_user_from(session).present? || session[:rbrun_user_id].present?
    rescue StandardError
      false
    end

    def relay(request, run)
      path = request.fullpath.sub(%r{\A/}, "") # keeps the query string; "" for the root
      url  = "#{run.url.to_s.chomp('/')}/#{path}"

      body = request.body&.read.presence
      upstream = connection.run_request(request.request_method.downcase.to_sym, url, body, forward_headers(request, run))

      headers = upstream.headers.reject { |k, _| HOP_BY_HOP.include?(k.to_s.downcase) }
      [ upstream.status, headers, [ upstream.body.to_s ] ]
    end

    # The provider preview token is attached HERE, server-side, and never reaches the client.
    def forward_headers(request, run)
      headers = { "x-daytona-preview-token" => run.token.to_s }
      headers["content-type"] = request.content_type if request.content_type.present?
      accept = request.get_header("HTTP_ACCEPT")
      headers["accept"] = accept if accept.present?
      headers
    end

    def connection
      @connection ||= Faraday.new { |f| f.adapter :async_http }
    end

    def not_found   = [ 404, { "content-type" => "text/plain" }, [ "No such preview." ] ]
    def unavailable = [ 503, { "content-type" => "text/plain" }, [ "This preview is not running." ] ]
    def require_login = [ 403, { "content-type" => "text/plain" }, [ "This preview is private — sign in to rbrun to view it." ] ]
  end
end
