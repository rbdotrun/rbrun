# frozen_string_literal: true

require_relative "support"

# THE end-to-end proof, in ONE session, TWO agent turns:
#
#   Turn 1 (deploy): a real agent turn preps DOGFOOD_APP_REPO in a Daytona box (rails-kamal-deployment
#     skill — Dockerfile, config/deploy.yml reading KAMAL_* env, a Postgres accessory, .kamal/secrets,
#     synced Gemfile.lock), COMMITS + PUSHES, then provision_server -> create_deploy_dns -> deploy. We
#     approve the gate + run the job for real, iterate on real errors, and prove the live HTTPS URL.
#
#   >> Between turns we DESTROY the dev box <<  — the deployment stays up; the box the agent worked in
#     is gone, exactly like a box lost between turns.
#
#   Turn 2 (teardown): the SAME session, resolved onto a FRESH box. AgentTurn's ClaudeSnapshot restores
#     the whole .claude, so the SDK RESUMES this conversation with its own deploy context — and the agent
#     calls teardown_deploy ITSELF (never us scripting it). We confirm the server + DNS are gone and the
#     URL is dead. THAT resume-on-a-fresh-box is the turn-idempotency proof.
#
# Along the way we assert the snapshot was captured (turn 1) and consumed (turn 2). Reaps prior state at
# start and archive!s at the end (idempotent — invariant #11). Never variabilized.
#
#   bin/rails app:dogfood:agent_lifecycle
namespace :dogfood do
  desc "Agent lifecycle: one session deploys (turn 1), loses its box, then tears down on a fresh box (turn 2)"
  task agent_lifecycle: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    require "securerandom"
    require "net/http"
    %w[ANTHROPIC_OAUTH_TOKEN DAYTONA_API_KEY HETZNER_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_ZONE_ID
       KAMAL_REGISTRY_SERVER KAMAL_REGISTRY_USERNAME KAMAL_REGISTRY_PASSWORD RBRUN_PREVIEW_DOMAIN
       DOGFOOD_APP_REPO DOGFOOD_APP_MASTER_KEY].each { |k| abort "Missing .env #{k}" if ENV[k].to_s.empty? }

    domain = ENV["RBRUN_PREVIEW_DOMAIN"]
    repo   = ENV["DOGFOOD_APP_REPO"]
    tenant = "dogfood"
    pat    = `gh auth token`.strip
    abort "no gh token" if pat.empty?

    Rbrun.configure do |c|
      c.github_pat = pat
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 60 } }
      c.server_provider  = { default: :kamal_hetzner, kamal_hetzner: { hcloud_token: ENV["HETZNER_API_TOKEN"],
                             registry: { server: ENV["KAMAL_REGISTRY_SERVER"], username: ENV["KAMAL_REGISTRY_USERNAME"], password: ENV["KAMAL_REGISTRY_PASSWORD"] } } }
      c.dns_provider     = { default: :cloudflare, cloudflare: { api_token: ENV["CLOUDFLARE_API_KEY"], zone_id: ENV["CLOUDFLARE_ZONE_ID"] } }
    end
    Rbrun.config.preview_domain = domain
    Rbrun::ApplicationJob.queue_adapter = :test # capture the enqueue; we run the deploy job once, below

    # Store the app's secrets so the agent doesn't have to ask in this headless run.
    Rbrun::RepoSecret.find_or_create_by!(tenant:, repo:, key: "RAILS_MASTER_KEY") { |s| s.value = ENV["DOGFOOD_APP_MASTER_KEY"] }
    Rbrun::RepoSecret.find_or_create_by!(tenant:, repo:, key: "POSTGRES_PASSWORD") { |s| s.value = SecureRandom.hex(16) }

    # Reap prior dogfood worktrees via the ONE teardown entry point (idempotency, invariant #11).
    Rbrun::Worktree.for_tenant(tenant).where(repo:, archived_at: nil).find_each(&:archive!)

    worktree = Rbrun::Worktree.create!(tenant:, repo:, base: "main")
    dog.header "provisioning the dev sandbox (clone #{repo} + push the branch)"
    worktree.provision!
    session = worktree.sessions.create!

    begin
      # ── TURN 1 — deploy ───────────────────────────────────────────────────────────────────────────
      dog.header "TURN 1 — deploy (prep -> commit+push -> provision -> dns -> deploy -> ITERATE)"
      session.run_turn(<<~MSG)
        Deploy this Rails app to a live public HTTPS URL using the rails-kamal-deployment skill.
        It uses Postgres. Prepare the repo (add/fix the Kamal setup — Dockerfile, config/deploy.yml
        reading the KAMAL_* env, a Postgres accessory, .kamal/secrets, and SYNC the Gemfile.lock),
        COMMIT and PUSH, then call provision_server, create_deploy_dns, and deploy. After deploying,
        poll deploy_status; if it failed, read deploy_logs, fix the real error, push, and deploy again —
        repeat until it is deployed. RAILS_MASTER_KEY and POSTGRES_PASSWORD are already stored. Then give
        me the URL.
      MSG

      # Let the AGENT iterate: approve each gated deploy, RUN it for real (so status/logs are truthful),
      # then resume so the agent reads the result and, on failure, fixes the ACTUAL error and redeploys.
      8.times do
        session.reload
        break unless session.needs_approval?
        pending = session.messages.approval_pending.last
        break unless pending&.payload&.dig("name") == "deploy"
        nudge = pending.decide_approval!(:approve)
        Rbrun::DeployJob.perform_now(worktree.id)
        st = worktree.reload.deploy_target&.status
        dog.info "deploy attempt -> ", st
        break if st == "deployed"
        session.continue_turn!(nudge)
      end

      target = worktree.reload.deploy_target
      url    = target&.url
      name   = "rbrun-w#{worktree.id}"
      dog.ok "agent provisioned a server",           target&.server_ip.present?
      dog.ok "agent drove the deploy to 'deployed'", target&.status == "deployed"
      dog.ok "#{url} serves 200 over HTTPS",          url && poll_https_200(url, tries: 45)
      puts "\n🔗  LIVE:  #{url}\n\n"

      # The snapshot must exist NOW — turn 1 wrote it, and it is what turn 2 will resume from.
      dog.ok "turn 1 captured the .claude snapshot", session.reload.snapshot&.data.present?

      # ── LOSE THE BOX ──────────────────────────────────────────────────────────────────────────────
      dog.header "destroying the dev box (a box lost between turns)"
      worktree.sandbox.destroy! # nils the adapter's box id; turn 2's first sandbox call find-or-creates a FRESH one
      dog.info "dev box destroyed", "turn 2 resolves a fresh box; ClaudeSnapshot must restore .claude for resume"

      # ── TURN 2 — teardown, SAME session, FRESH box ────────────────────────────────────────────────
      dog.header "TURN 2 — same session, fresh box: the AGENT tears down #{url}"
      session.run_turn(<<~MSG)
        The deployment you created is live at #{url}. We're done with it — tear it down completely so it
        stops costing us: destroy the server and remove its DNS record. Use your teardown tool to do it,
        then confirm the deployment is gone.
      MSG
      6.times do # only fires if the agent parks on a gate (e.g. ask_user); teardown_deploy is ungated.
        session.reload
        break unless session.needs_approval?
        pending = session.messages.approval_pending.last
        break if pending.nil?
        session.continue_turn!(pending.decide_approval!(:approve))
      end

      target = worktree.reload.deploy_target
      dog.ok "agent (resumed on a fresh box) marked it torn_down", target&.status == "torn_down"
      dog.ok "server gone from Hetzner",                          Rbrun.server.find_server(name:).nil?
      dog.ok "#{url} no longer answers",                         url_dead?(url)
    ensure
      # Final cleanup — the ONE teardown entry point: reaps the box + soft-deletes (idempotent).
      begin
        worktree.archive!
      rescue StandardError
        nil
      end
    end
  end
end

def poll_https_200(url, tries: 45)
  uri = URI(url)
  tries.times do
    begin
      res = Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.get("/") }
      return true if res.code.to_i == 200
    rescue StandardError
      # not up yet
    end
    sleep 10
  end
  false
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
