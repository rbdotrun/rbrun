# frozen_string_literal: true

require_relative "support"

# The engine's OWN preview edge, proven against a REAL Daytona sandbox. Drives the actual
# Rbrun::PreviewProxy middleware in-process (no tunnel/server to orchestrate — bin/setup proves the
# Cloudflare hop separately) against a live service, asserting: the app + its assets relay anonymously
# for a PUBLIC service, the provider token is attached SERVER-SIDE, and the sandbox is NEVER made public.
#
#   bin/rails app:dogfood:preview_edge      (needs .env: DAYTONA_API_KEY/URL)
namespace :dogfood do
  desc "Preview edge: the engine's own proxy relays a real Daytona service (app + assets), box stays private"
  task preview_edge: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env Daytona creds." if ENV["DAYTONA_API_KEY"].to_s.empty?

    require "rack/mock"
    require "faraday"
    require "async/http/faraday"

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
    end
    Rbrun.config.preview_domain = "rb.run" # so token_from_host matches; the proxy needs no real DNS to run in-process

    # IDEMPOTENCY (invariant #11): reap any leftover box from a prior, interrupted run of THIS dogfood
    # before creating a new one, so an aborted run can never accumulate. (The happy path also destroys in
    # `ensure` below.)
    Rbrun::Worktree.for_tenant("edge").where(repo: "rbdotrun/edge").find_each do |old|
      old.sandbox.destroy!
    rescue StandardError
      nil
    ensure
      old.destroy
    end

    worktree = Rbrun::Worktree.create!(tenant: "edge", repo: "rbdotrun/edge")
    session  = worktree.sessions.create!
    launcher = Rbrun::ServiceLauncher.new(worktree: worktree)

    # A tiny bun static server: HTML that references /style.css (proves root-relative assets relay).
    server_js = <<~JS
      Bun.serve({ port: 8080, fetch(req) {
        const p = new URL(req.url).pathname;
        if (p === "/style.css") return new Response("body{color:tomato}", { headers: { "content-type": "text/css" } });
        return new Response('<!doctype html><html><head><link rel="stylesheet" href="/style.css"></head><body>rbrun-edge-ok</body></html>', { headers: { "content-type": "text/html" } });
      }});
    JS

    # Drive the REAL middleware in-process. Returns [status, headers, body_string].
    def hit(host, path)
      env = Rack::MockRequest.env_for("http://#{host}#{path}")
      status, headers, body = Rbrun::PreviewProxy.new(->(_) { [ 404, {}, [ "fell-through" ] ] }).call(env)
      chunks = +""
      body.each { |c| chunks << c }
      [ status, headers, chunks ]
    end

    begin
      dog.header "provision a real box + a running HTTP service"
      worktree.sandbox.write("server.js", server_js)
      launcher.start([ { "name" => "web", "command" => "bun /home/daytona/workspace/server.js", "port" => 8080 } ])
      run = worktree.service_runs.find_by(name: "web")
      dog.ok "web is running in the sandbox", run&.status_running?

      dog.header "preview + share (the engine's ladder — never the provider switch)"
      exp = launcher.preview("web")
      launcher.share_public("web")
      dog.ok "an exposure token was minted", exp.preview_token.present?
      dog.ok "the run carries the provider upstream + token", run.reload.url.present? && run.token.present?
      dog.info "preview host", exp.preview_host
      host = exp.preview_host

      # Give bun a moment to bind.
      sleep 2

      dog.header "the engine's OWN proxy relays the real app, anonymously"
      status, _headers, body = hit(host, "/")
      dog.info "GET / via proxy", "#{status} #{body.squish[0, 60]}"
      dog.ok "the real app is relayed (200, its HTML)", status == 200 && body.include?("rbrun-edge-ok")

      dog.header "assets relay through the SAME host (no path rewriting)"
      as, _h, ab = hit(host, "/style.css")
      dog.ok "the asset relays anonymously (200, its CSS)", as == 200 && ab.include?("tomato")

      dog.header "the provider token is server-side only"
      dog.ok "the token never appears in the relayed body", !body.include?(run.token.to_s)

      dog.header "the SANDBOX itself was never made public"
      conn = Faraday.new { |f| f.adapter :async_http }
      anon = begin
        u = run.url
        st = nil
        6.times do
          r = conn.get(u)
          st = r.status
          loc = r.headers["location"]
          break unless loc && st.between?(300, 399)

          u = loc.start_with?("http") ? loc : URI.join(u, loc).to_s
        end
        [ st, u ]
      rescue StandardError => e
        [ "err:#{e.class}", nil ]
      end
      dog.info "raw provider url, anonymous", "#{anon.first} → #{anon.last.to_s[0, 50]}"
      dog.ok "the raw provider URL still demands provider auth (box private)", anon.last.to_s.match?(/auth0|login/)

      dog.header "revocation"
      launcher.stop_preview("web")
      st2, = hit(host, "/") # same host — the token is stable, but the upstream is withdrawn
      dog.info "status after stop_preview", st2
      dog.ok "after stop_preview the preview is NO LONGER SERVED (not 200)", st2 != 200
    ensure
      worktree.sandbox.destroy!
      worktree.destroy!
      Rbrun.config.preview_domain = nil
    end
  end
end
