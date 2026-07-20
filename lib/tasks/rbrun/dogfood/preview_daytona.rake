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
      dog.header "provision the app into the box (upload the local checkout — private repo, no PAT)"
      # benbonnet/dummy-rails is private and there's no GITHUB_PAT, so worktree.provision! (a PAT clone +
      # push) can't run. The harness uploads a `git archive` of the local checkout's HEAD — tracked files
      # only, so config/master.key (gitignored) stays OUT and still arrives via request_secrets. This is
      # harness plumbing standing in for the clone, exactly as it stands in for the user's form entry.
      require "open3"
      local = "/Users/ben/Desktop/sources/dummy-rails"
      archive, st = Open3.capture2("git", "-C", local, "archive", "--format=tar.gz", "HEAD")
      abort "git archive of #{local} failed" unless st.success?
      ws = worktree.sandbox.workspace
      worktree.sandbox.write("app.tgz", archive)
      worktree.sandbox.exec!("cd #{ws} && tar xzf app.tgz && rm -f app.tgz", timeout: 180)
      dog.ok "the app is in the box", worktree.sandbox.exist?("Gemfile")

      # ── one real turn: the agent gathers the secret, then starts the services ──────────────────────
      dog.header "a real turn drives request_secrets → repo_services_start"
      session.run_turn(<<~MSG)
        Get this Rails app's web server listening on port 3000 so I can preview it. Steps:
        1. Run `bundle install` (a one-shot command, not a service).
        2. Call request_secrets to ask me for RAILS_MASTER_KEY (it is in config/master.key).
        3. The app uses PostgreSQL. Start a local postgres and prepare the database (`bin/rails
           db:prepare`); set POSTGRES_HOST/PORT/USER/PASSWORD/DB env as needed. If the DB proves hard,
           still get the web server LISTENING on port 3000 — a bound port is the priority.
        4. Start the web server with repo_services_start:
           `bin/rails server -b 0.0.0.0 -p 3000` on port 3000.
        Use the repo_services tools for anything long-lived; debug failures with repo_services_logs.
        Do not background anything with `&`.
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

      dog.header "what the agent actually did (diagnostics)"
      if start_gate
        proposed = Array(start_gate.payload.dig("input", "services"))
        dog.info "proposed services", proposed.map { |s| "#{s['name']}:#{s['port']}=#{s['command']}" }.join(" | ")[0, 240]
        sres = session.messages.where(event_type: "tool_result", tool_use_id: start_gate.tool_use_id).last
        dog.info "start result", sres&.payload&.dig("result").to_json[0, 300]
      end
      sup = Rbrun::ServiceSupervisor.new(worktree: worktree)
      worktree.service_runs.reload.each do |r|
        dog.info "service", "#{r.name} port=#{r.port || '-'} status=#{r.status} url=#{r.url.presence || '-'}"
        dog.info "  logs", sup.tail(r, lines: 6).to_s.squish[0, 200]
      end

      # ── THE CRUX (§7): verify the Daytona preview WIRE directly — independent of whether Rails booted. ──
      # preview_url(3000) resolves the proxy URL + token; hitting it tells us the proxy+token mechanism
      # works (even a 502/500 back means the wire delivered us; only a connection error / proxy-4xx fails).
      dog.header "verify the Daytona preview URL + token wire (§7)"
      require "faraday"
      require "async/http/faraday"
      begin
        link = worktree.sandbox.preview_url(3000)
        dog.ok "preview_url(3000) resolved a URL", link.url.present?
        dog.info "preview url", link.url
        dog.info "token present", (!link.token.to_s.empty?).to_s
        conn = Faraday.new { |f| f.adapter :async_http }
        by_header = begin
          conn.get(link.url) { |r| r.headers["x-daytona-preview-token"] = link.token if link.token.present? }.status
        rescue StandardError => e
          "err:#{e.class}"
        end
        by_query = begin
          u = link.token.present? ? "#{link.url}#{link.url.include?('?') ? '&' : '?'}token=#{CGI.escape(link.token)}" : link.url
          conn.get(u).status
        rescue StandardError => e
          "err:#{e.class}"
        end
        dog.info "status via x-daytona-preview-token header", by_header.inspect
        dog.info "status via ?token= query", by_query.inspect
        reached = [ by_header, by_query ].select { |s| s.is_a?(Integer) }.any? { |s| s.between?(200, 599) }
        dog.ok "the preview URL + token reach the box (any HTTP status ⇒ the wire works)", reached
        dog.info "next", "adapt Client#preview_link + ServicesController#preview_target to the mechanism that returned a status"
      rescue StandardError => e
        dog.ok "preview_url(3000) resolved (Daytona wire)", false
        dog.info "preview_url error", "#{e.class}: #{e.message}"[0, 240]
        dog.info "next", "fix Rbrun::Sandbox::Daytona::Client#preview_link — the endpoint/shape is wrong; see the error above"
      end
    ensure
      session.sandbox.destroy!
      worktree.destroy!
      Rbrun::RepoSecret.for_tenant(tenant).for_repo(repo).delete_all
      Rbrun::RepoService.for_tenant(tenant).for_repo(repo).delete_all
    end
  end
end
