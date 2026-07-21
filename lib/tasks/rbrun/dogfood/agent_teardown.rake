# frozen_string_literal: true

require_relative "support"

# Validate teardown THROUGH THE AGENT — run after app:dogfood:agent_deploy proved the live URL and left the
# worktree (deployment + sandbox) up. This REUSES THE SAME SESSION and asks the agent to reap its own
# deployment: the agent must call teardown_deploy ITSELF (proving it understood), never us scripting it.
# The SDK resumes in the still-live box, so the agent has its own deploy context. Then we confirm the
# server + DNS are gone and the URL no longer answers, and finally archive! the worktree (the ONE teardown
# entry point: reaps the dev sandbox + soft-deletes, idempotent — invariant #11). Never variabilized.
#
#   bin/rails app:dogfood:agent_teardown
namespace :dogfood do
  desc "Agent teardown: reuse the deploy session and have the AGENT reap its own deployment"
  task agent_teardown: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    require "net/http"
    %w[ANTHROPIC_OAUTH_TOKEN DAYTONA_API_KEY HETZNER_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_ZONE_ID
       RBRUN_PREVIEW_DOMAIN DOGFOOD_APP_REPO].each { |k| abort "Missing .env #{k}" if ENV[k].to_s.empty? }

    domain = ENV["RBRUN_PREVIEW_DOMAIN"]
    repo   = ENV["DOGFOOD_APP_REPO"]
    tenant = "dogfood"
    pat    = `gh auth token`.strip
    abort "no gh token" if pat.empty?

    Rbrun.configure do |c|
      c.github_pat = pat
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 30 } }
      c.server_provider  = { default: :kamal_hetzner, kamal_hetzner: { hcloud_token: ENV["HETZNER_API_TOKEN"] } }
      c.dns_provider     = { default: :cloudflare, cloudflare: { api_token: ENV["CLOUDFLARE_API_KEY"], zone_id: ENV["CLOUDFLARE_ZONE_ID"] } }
    end
    Rbrun.config.preview_domain = domain

    # The SAME worktree + session the deploy dogfood left up (its most recent live one for this repo).
    worktree = Rbrun::Worktree.for_tenant(tenant).where(repo: repo, archived_at: nil).order(:id).last
    abort "no live dogfood worktree — run app:dogfood:agent_deploy first" if worktree.nil?
    session = worktree.sessions.order(:id).last
    abort "worktree ##{worktree.id} has no session to resume" if session.nil?

    target = worktree.deploy_target
    url    = target&.url
    name   = "rbrun-w#{worktree.id}"

    dog.header "reuse session ##{session.id} (worktree ##{worktree.id}) — ask the AGENT to tear down #{url}"
    begin
      session.run_turn(<<~MSG)
        The deployment you created is live at #{url}. We're done with it — tear it down completely so it
        stops costing us: destroy the server and remove its DNS record. Use your teardown tool to do it,
        then confirm the deployment is gone.
      MSG

      # teardown_deploy is ungated, so the agent just calls it. This loop only covers the case where the
      # agent parks on a gate (e.g. ask_user) — approve and let it continue. The AGENT drives the reap.
      6.times do
        session.reload
        break unless session.needs_approval?
        pending = session.messages.approval_pending.last
        break if pending.nil?
        session.continue_turn!(pending.decide_approval!(:approve))
      end

      target = worktree.reload.deploy_target
      dog.ok "agent marked the deployment torn_down", target&.status == "torn_down"
      dog.ok "server gone from Hetzner",             Rbrun.server.find_server(name: name).nil?
      dog.ok "#{url} no longer answers",             url_dead?(url)
    ensure
      # Final cleanup — the ONE teardown entry point: reaps the dev sandbox + soft-deletes (idempotent).
      begin
        worktree.archive!
      rescue StandardError
        nil
      end
    end
  end
end

# Down = not reachable / not 200. After server destroy + DNS removal the host stops resolving, so a
# connection error is the expected success signal.
def url_dead?(url)
  return true if url.to_s.empty?

  uri = URI(url)
  6.times do
    begin
      res = Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.get("/") }
      return false if res.code.to_i == 200
    rescue StandardError
      return true
    end
    sleep 5
  end
  false
end
