# frozen_string_literal: true

require_relative "support"

# The REAL end-to-end repo-services gate: a live Daytona box running benbonnet/dummy-rails, driven by a
# real Claude turn, with secrets gathered through request_secrets and the HTTP service exposed as a
# Daytona preview. Its PURPOSE is to VERIFY THE ONE UNVERIFIED WIRE — the Daytona preview_url shape and
# the browser token mechanism through services/:id/open (§7 of the design).
#
# ⚠ FIRED MANUALLY — needs .env creds (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY, DAYTONA_API_URL), a
# github_pat that can read benbonnet/dummy-rails, and the local checkout at
# /Users/ben/Desktop/sources/dummy-rails (the harness reads config/master.key to stand in for the user
# filling the secure form). The custom Dockerfile (ruby+node+postgres+bun) may need refining on first run.
#
#   bin/rails app:dogfood:preview_daytona
namespace :dogfood do
  desc "REAL: dummy-rails on Daytona — request_secrets + repo services + verify the preview URL/token wire"
  task preview_daytona: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    master_key_path = "/Users/ben/Desktop/sources/dummy-rails/config/master.key"
    abort "Missing #{master_key_path} (the user's secret)." unless File.exist?(master_key_path)
    rails_master_key = File.read(master_key_path).strip # the harness stands in for the user's form entry

    # A box that can run a Rails app: ruby + node + postgres + git, plus bun for the agent loop (client.ts).
    dockerfile = <<~DOCKER
      FROM ruby:3.4-bookworm
      RUN apt-get update && apt-get install -y --no-install-recommends \\
            git ca-certificates curl unzip postgresql postgresql-contrib nodejs npm \\
        && useradd -m daytona \\
        && mkdir -p /home/daytona/workspace && chown -R daytona:daytona /home/daytona \\
        && apt-get clean && rm -rf /var/lib/apt/lists/*
      USER daytona
      ENV BUN_INSTALL=/home/daytona/.bun
      ENV PATH=/home/daytona/.bun/bin:$PATH
      RUN curl -fsSL https://bun.sh/install | bash
      WORKDIR /home/daytona/workspace
    DOCKER

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"], dockerfile: dockerfile } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 30 } }
      c.github_pat = ENV["GITHUB_PAT"] if ENV["GITHUB_PAT"].present?
    end

    tenant   = "dogfood"
    repo     = "benbonnet/dummy-rails"
    Rbrun::RepoSecret.for_tenant(tenant).for_repo(repo).delete_all
    Rbrun::RepoService.for_tenant(tenant).for_repo(repo).delete_all

    worktree = Rbrun::Worktree.create!(tenant: tenant, repo: repo, base: "main")
    session  = worktree.sessions.create!

    begin
      dog.header "provision the app into the box"
      worktree.provision!
      dog.ok "the repo cloned", worktree.head_sha.present?

      # ── one real turn: the agent gathers the secret, then starts the services ──────────────────────
      dog.header "a real turn drives request_secrets → repo_services_start"
      session.run_turn(<<~MSG)
        Get this Rails app running so I can preview it. First call request_secrets to ask me for
        RAILS_MASTER_KEY (it's in config/master.key). Then start its services with repo_services_start:
        a postgres database, run bin/rails db:prepare, and the web server on port 3000. Use the repo
        services tools — do not background anything with &.
      MSG

      # The turn parks on the request_secrets custom gate. Stand in for the user: submit the master key
      # through the SAME path the SecretsController takes (validate → encrypt+store → keys-only resume).
      secrets_gate = session.messages.approval_pending.where(event_type: "tool_use").find { |m| m.payload.dig("name") == "request_secrets" }
      dog.ok "the agent asked for secrets (request_secrets parked)", secrets_gate.present?
      if secrets_gate
        spec = Rbrun::SecretsFormSpec.new(secrets_gate.payload["input"])
        submitted = { "RAILS_MASTER_KEY" => rails_master_key }
        dog.ok "the submission validates against the frozen spec", spec.errors(submitted).empty?
        Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "RAILS_MASTER_KEY") { |s| s.value = rails_master_key }
        secrets_gate.update!(approval_status: "answered")
        session.messages.create!(role: "tool", event_type: "tool_result", tool_use_id: secrets_gate.tool_use_id,
          content: { "stored_keys" => %w[RAILS_MASTER_KEY] }.to_json,
          payload: { "tool_use_id" => secrets_gate.tool_use_id, "result" => { "stored_keys" => %w[RAILS_MASTER_KEY] }, "is_error" => false })
        result_json = session.messages.where(event_type: "tool_result", tool_use_id: secrets_gate.tool_use_id).last.payload.to_json
        dog.ok "the master key NEVER appears in the tool_result", !result_json.include?(rails_master_key)
        session.continue_turn!(spec.stored_recap(%w[RAILS_MASTER_KEY]))
      end

      # The turn then parks on the repo_services_start approval gate. Approve it (runs the launcher).
      start_gate = session.reload.messages.approval_pending.where(event_type: "tool_use").find { |m| m.payload.dig("name") == "repo_services_start" }
      dog.ok "the agent proposed services (repo_services_start parked for approval)", start_gate.present?
      if start_gate
        nudge = start_gate.decide_approval!("approve") # runs ServiceLauncher#start via run_frozen_call!
        session.continue_turn!(nudge) if nudge
      end

      dog.header "the services are running with a resolved preview"
      web = worktree.service_runs.reload.find_by(name: "web") || worktree.service_runs.find { |r| r.port.present? }
      dog.ok "a web service is running", web&.status_running?
      dog.ok "Daytona resolved a preview url", web&.url.present?
      dog.info "preview url", web&.url
      dog.info "has token", (!web&.token.to_s.empty?).to_s

      # ── THE CRUX: verify the browser token mechanism through the engine's open endpoint logic ──────
      dog.header "verify the preview URL/token opens the live app (the §7 unknown)"
      require "faraday"
      require "async/http/faraday"
      target = web&.url.to_s
      conn = Faraday.new { |f| f.adapter :async_http }
      # Try the two mechanisms Daytona's proxy may accept, and report which serves the Rails app.
      by_header = (conn.get(target) { |r| r.headers["x-daytona-preview-token"] = web.token if web&.token.present? }.status rescue nil)
      by_query  = begin
        u = web&.token.present? ? "#{target}#{target.include?('?') ? '&' : '?'}token=#{CGI.escape(web.token)}" : target
        conn.get(u).status
      rescue StandardError
        nil
      end
      dog.info "status via x-daytona-preview-token header", by_header.inspect
      dog.info "status via ?token= query", by_query.inspect
      dog.ok "the live Rails app is reachable through the preview (one mechanism returned 2xx/3xx)",
             [ by_header, by_query ].compact.any? { |s| s.to_i.between?(200, 399) }
      dog.info "→ adapt ServicesController#preview_target + Client#preview_link to the mechanism that worked"
    ensure
      session.sandbox.destroy!
      worktree.destroy!
      Rbrun::RepoSecret.for_tenant(tenant).for_repo(repo).delete_all
      Rbrun::RepoService.for_tenant(tenant).for_repo(repo).delete_all
    end
  end
end
