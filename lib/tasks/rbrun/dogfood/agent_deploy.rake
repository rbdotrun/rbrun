# frozen_string_literal: true

require_relative "support"

# THE proof: a REAL agent turn drives the deployment. The agent (rails-kamal-deployment skill) inspects
# DOGFOOD_APP_REPO in a Daytona sandbox, adds/fixes the Kamal setup, COMMITS + PUSHES, then calls
# provision_server -> create_deploy_dns -> deploy. We approve the deploy gate (standing in for the human),
# run the deploy job, and prove the live URL. On success the WHOLE worktree stays UP — the deployment AND
# its dev sandbox — so app:dogfood:agent_teardown can REUSE THE SAME SESSION and have the agent reap it
# (the SDK resumes in that live box). The next deploy run reaps prior worktrees at start via archive!
# (idempotent, invariant #11), so at most one is ever left behind. Never variabilized.
#
#   bin/rails app:dogfood:agent_deploy
namespace :dogfood do
  desc "Agent deploy: a real turn preps DOGFOOD_APP_REPO, commits+pushes, and deploys to a live URL"
  task agent_deploy: :environment do
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
    host   = "dogfood-app.#{domain}"
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
    Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "RAILS_MASTER_KEY") { |s| s.value = ENV["DOGFOOD_APP_MASTER_KEY"] }
    Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "POSTGRES_PASSWORD") { |s| s.value = SecureRandom.hex(16) }

    # Reap prior dogfood worktrees via the ONE teardown entry point — archive! guarantees sandbox + server +
    # DNS are gone (idempotency, invariant #11). No hand-reaping.
    Rbrun::Worktree.for_tenant(tenant).where(repo: repo, archived_at: nil).find_each(&:archive!)

    worktree = Rbrun::Worktree.create!(tenant: tenant, repo: repo, base: "main")
    dog.header "provisioning the dev sandbox (clone #{repo} + push the branch)"
    worktree.provision!
    session = worktree.sessions.create!

    begin
      dog.header "the agent turn (prep -> commit+push -> provision -> dns -> deploy -> ITERATE)"
      session.run_turn(<<~MSG)
        Deploy this Rails app to a live public HTTPS URL using the rails-kamal-deployment skill.
        It uses Postgres. Prepare the repo (add/fix the Kamal setup — Dockerfile, config/deploy.yml
        reading the KAMAL_* env, a Postgres accessory, .kamal/secrets, and SYNC the Gemfile.lock),
        COMMIT and PUSH, then call provision_server, create_deploy_dns, and deploy. After deploying,
        poll deploy_status; if it failed, read deploy_logs, fix the real error, push, and deploy again —
        repeat until it is deployed. RAILS_MASTER_KEY and POSTGRES_PASSWORD are already stored. Then give
        me the URL.
      MSG

      # Let the AGENT iterate: every time it calls the gated deploy, approve it, RUN the deploy for real
      # (so deploy_status/deploy_logs are truthful), then resume the agent so it reads the result and,
      # on failure, fixes the ACTUAL error and redeploys. The agent — not us — makes it work.
      8.times do
        session.reload
        break unless session.needs_approval?
        pending = session.messages.approval_pending.last
        break unless pending&.payload&.dig("name") == "deploy"
        nudge = pending.decide_approval!(:approve)      # marks deploying + enqueues the job
        Rbrun::DeployJob.perform_now(worktree.id)        # actually build + deploy — real result
        st = worktree.reload.deploy_target&.status
        dog.info "deploy attempt -> ", st
        break if st == "deployed"
        session.continue_turn!(nudge)                    # agent resumes, reads status/logs, fixes, retries
      end

      target = worktree.reload.deploy_target
      dog.ok "agent provisioned a server", target&.server_ip.present?
      dog.ok "agent drove the deploy to 'deployed'", target&.status == "deployed"
      puts target&.last_deploy_log.to_s.lines.last(20).join

      url = target&.url
      dog.header "prove the live URL"
      live = url && poll_https_200(url, tries: 45)
      dog.ok "#{url} serves 200 over HTTPS", !!live
      puts "\n🔗  LIVE:  #{url}\n\n"
      dog.info "left UP on purpose", "worktree + sandbox stay alive; validate teardown via app:dogfood:agent_teardown"
    end
    # No ensure-reap: the sandbox stays alive so agent_teardown can resume THIS session. The next deploy
    # run's start-reap (archive!) cleans it up, keeping at most one worktree behind (invariant #11).
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
