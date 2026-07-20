# frozen_string_literal: true

require "faraday"
require "async/http/faraday"
require "rbrun/preview_socket"

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

    # Live hijacked upgrades, process-global. On Puma each pins a thread, so it is capped
    # (preview_max_sockets); on Falcon the connection is a fiber and the cap can be lifted.
    @sockets = 0
    @mutex = Mutex.new
    class << self
      attr_accessor :sockets, :mutex
    end

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
      exposure = Rbrun::ServiceExposure.find_by(preview_token: token)
      return not_found unless exposure

      run = exposure.live_run # the running service in THIS worktree's sandbox — unambiguous
      return unavailable unless run&.url.present?

      # Level gate. Public ⇒ anyone. Private ⇒ an rbrun session is required (a teammate needs an rbrun
      # account, not a Daytona one). NOTE: for the private path across subdomains, the session cookie must
      # be scoped to ".<domain>" — otherwise the preview host never sees it. Public needs no session.
      return require_login unless exposure.shared_public? || authenticated?(request)

      websocket?(request) ? upgrade(request, run) : relay(request, run)
    end

    def websocket?(request) = request.get_header("HTTP_UPGRADE").to_s.casecmp?("websocket")

    # Hijack the browser socket and byte-bridge it to the sandbox's upstream websocket, with the provider
    # token attached server-side. Capped: past preview_max_sockets we REFUSE the upgrade (503) rather than
    # starve the app that is serving the UI.
    def upgrade(request, run)
      hijack = request.env["rack.hijack"]
      return [ 501, { "content-type" => "text/plain" }, [ "WebSocket not supported here." ] ] unless hijack

      return busy unless acquire_slot

      client = hijack.call || request.env["rack.hijack_io"]
      Thread.new do
        Rbrun::PreviewSocket.bridge(client, url: upstream_ws_url(request, run), headers: forward_headers(request, run))
      ensure
        release_slot
      end
      [ -1, {}, [] ] # hijacked — the server must not emit a response
    end

    def acquire_slot
      self.class.mutex.synchronize do
        return false if self.class.sockets >= Rbrun.config.preview_max_sockets.to_i

        self.class.sockets += 1
        true
      end
    end

    def release_slot = self.class.mutex.synchronize { self.class.sockets -= 1 }

    def upstream_ws_url(request, run)
      base = run.url.to_s.sub(%r{\Ahttp}, "ws").chomp("/")
      "#{base}/#{request.fullpath.sub(%r{\A/}, '')}"
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
      confine_cookies!(headers, request.host)
      [ upstream.status, headers, [ upstream.body.to_s ] ]
    end

    # The provider preview token is attached HERE, server-side, and never reaches the client. Cookies flow
    # untouched (the app authenticates its own users); the app is told it is on HTTPS so its Secure/
    # SameSite session cookies are set and sent.
    def forward_headers(request, run)
      headers = {
        "x-daytona-preview-token" => run.token.to_s,
        "x-forwarded-proto" => "https",
        "x-forwarded-host" => request.host,
        "cookie" => request.get_header("HTTP_COOKIE").to_s
      }
      headers["content-type"] = request.content_type if request.content_type.present?
      accept = request.get_header("HTTP_ACCEPT")
      headers["accept"] = accept if accept.present?
      headers.reject { |_, v| v.to_s.empty? }
    end

    # A proxied app's Set-Cookie must not widen its Domain past its own preview host — else it would bleed
    # across previews and the rbrun app itself. Strip any Domain attribute so the cookie stays host-only.
    def confine_cookies!(headers, _host)
      key = headers.keys.find { |k| k.to_s.casecmp?("set-cookie") }
      return unless key

      cookies = Array(headers[key])
      headers[key] = cookies.map { |c| c.to_s.gsub(/;\s*Domain=[^;]*/i, "") }
    end

    def connection
      @connection ||= Faraday.new { |f| f.adapter :async_http }
    end

    def not_found   = [ 404, { "content-type" => "text/plain" }, [ "No such preview." ] ]
    def unavailable = [ 503, { "content-type" => "text/plain" }, [ "This preview is not running." ] ]
    def require_login = [ 403, { "content-type" => "text/plain" }, [ "This preview is private — sign in to rbrun to view it." ] ]
    def busy = [ 503, { "content-type" => "text/plain" }, [ "Too many live preview connections — try again shortly." ] ]
  end
end
