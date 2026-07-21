# frozen_string_literal: true

require_relative "support"

# THE proof: a REAL agent turn drives the deployment. The agent (rails-kamal-deployment skill) inspects
# DOGFOOD_APP_REPO in a Daytona sandbox, adds/fixes the Kamal setup, COMMITS + PUSHES, then calls
# provision_server -> create_deploy_dns -> deploy. We approve the deploy gate (standing in for the human),
# run the deploy job, and prove the live URL. On success the deployment stays UP (proof) — reap the dev
# sandbox only; validate teardown separately (app:dogfood:server_teardown). Never variabilized.
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
    ActiveJob::Base.queue_adapter = :test # we run the deploy job ourselves, synchronously, below

    # Store the app's secrets so the agent doesn't have to ask in this headless run.
    Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "RAILS_MASTER_KEY") { |s| s.value = ENV["DOGFOOD_APP_MASTER_KEY"] }
    Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "POSTGRES_PASSWORD") { |s| s.value = SecureRandom.hex(16) }

    worktree = Rbrun::Worktree.create!(tenant: tenant, repo: repo, base: "main")
    dog.header "provisioning the dev sandbox (clone #{repo} + push the branch)"
    worktree.provision!
    session = worktree.sessions.create!

    begin
      dog.header "the agent turn (prep -> commit+push -> provision -> dns -> deploy)"
      session.run_turn(<<~MSG)
        Deploy this Rails app to a live public HTTPS URL using the rails-kamal-deployment skill.
        It uses Postgres. Prepare the repo (add/fix the Kamal setup — Dockerfile, config/deploy.yml
        reading the KAMAL_* env, a Postgres accessory, .kamal/secrets), COMMIT and PUSH your changes,
        then call provision_server, create_deploy_dns, and deploy. RAILS_MASTER_KEY and POSTGRES_PASSWORD
        are already stored as secrets. When finished, tell me the URL.
      MSG

      # Approve the deploy gate (the human's yes), then let the agent finish its turn.
      if session.reload.needs_approval?
        pending = session.messages.approval_pending.last
        dog.info "approving gate", pending&.payload&.dig("name")
        nudge = pending.decide_approval!(:approve)
        session.continue_turn!(nudge) if nudge
      end

      target = worktree.reload.deploy_target
      dog.ok "agent provisioned a server", target&.server_ip.present?
      dog.ok "agent pushed the branch (deployable)", Rbrun::DeployRunner.branch_pushed?(worktree)

      if target&.server_ip.present? && Rbrun::DeployRunner.branch_pushed?(worktree)
        dog.header "running the deploy (kamal, synchronous)"
        result = Rbrun::DeployRunner.new(worktree: worktree).run!
        puts result.output.to_s.lines.last(30).join
        dog.ok "kamal deploy succeeded", result.ok
      end

      dog.header "prove the live URL"
      live = poll_https_200("https://#{host}", tries: 45)
      dog.ok "https://#{host} serves 200 over HTTPS", live
      puts "\n🔗  LIVE:  https://#{host}\n\n"
      dog.info "left UP on purpose", "validate teardown with: bin/rails app:dogfood:server_teardown"
    ensure
      # Reap only the DEV sandbox; the deployment stays up as proof.
      begin
        worktree.sandbox.destroy!
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
