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

      # ── the gate driver: stand in for the user at EACH gate as it parks (reused by both phases) ────
      saw_secrets = saw_start = checked = false
      start_gate = nil
      drive = lambda do
        25.times do
          session.reload
          break if session.done? || session.failed?

          gate = session.messages.approval_pending.where(event_type: "tool_use").order(:id).last
          break unless gate

          if gate.payload["name"] == "request_secrets"
            saw_secrets = true
            spec = Rbrun::SecretsFormSpec.new(gate.payload["input"])
            unless checked
              dog.ok "the secrets submission validates against the frozen spec", spec.errors("RAILS_MASTER_KEY" => rails_master_key).empty?
            end
            Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "RAILS_MASTER_KEY") { |s| s.value = rails_master_key }
            # The web service gets RAILS_MASTER_KEY via injected env (.rbrun/env). But the agent's own bash
            # one-shots (bundle, db:prepare) don't — so also drop the conventional master.key file.
            worktree.sandbox.write("config/master.key", rails_master_key)
            gate.update!(approval_status: "answered")
            session.messages.create!(role: "tool", event_type: "tool_result", tool_use_id: gate.tool_use_id,
              content: { "stored_keys" => %w[RAILS_MASTER_KEY] }.to_json,
              payload: { "tool_use_id" => gate.tool_use_id, "result" => { "stored_keys" => %w[RAILS_MASTER_KEY] }, "is_error" => false })
            unless checked
              result_json = session.messages.where(event_type: "tool_result", tool_use_id: gate.tool_use_id).last.payload.to_json
              dog.ok "the master key NEVER appears in the tool_result", !result_json.include?(rails_master_key)
            end
            checked = true
            session.continue_turn!(spec.stored_recap(%w[RAILS_MASTER_KEY]))
          else # repo_services_start (or any other needs_approval gate) → approve, runs the launcher
            if gate.payload["name"] == "repo_services_start"
              saw_start = true
              start_gate ||= gate
            end
            nudge = gate.decide_approval!("approve")
            session.continue_turn!(nudge) if nudge
          end
        end
      end

      # ── PHASE 1: run the services. Starting must NOT expose anything. ──────────────────────────────
      dog.header "phase 1 — a real turn brings the services up (NO preview)"
      session.run_turn(<<~MSG)
        Get this Rails app running so I can work with it. Work in this order.
        Use your bash tool for one-shot setup, and repo_services_start for the long-lived services.

        1. `bundle install`
        2. Call request_secrets to ask me for RAILS_MASTER_KEY (label it clearly). After I provide it,
           config/master.key will be present.
        3. Bring up PostgreSQL (the app uses solid_queue/cache/cable → several databases). Recipe for
           this Debian box, as the `daytona` user:
             - `initdb -D $HOME/pgdata`
             - make local TCP trust: append to $HOME/pgdata/pg_hba.conf:
                 `host all all 127.0.0.1/32 trust` and `host all all ::1/128 trust`
             - start it as a service via repo_services_start, name "db":
                 `postgres -D /home/daytona/pgdata -p 5432 -c listen_addresses=localhost`
             - create the role+db the app expects (host localhost, port 5432, user `daytona`):
                 `createdb -h localhost -p 5432 rails_dummy_development` (and let db:prepare make the rest)
        4. `POSTGRES_HOST=localhost POSTGRES_PORT=5432 POSTGRES_USER=daytona bin/rails db:prepare`
           (this creates rails_dummy_development and the _cache/_queue/_cable databases).
        5. Start the remaining services via repo_services_start (ONE call, all services together):
             - "web", port 3000:
               `POSTGRES_HOST=localhost POSTGRES_PORT=5432 POSTGRES_USER=daytona bin/rails server -b 0.0.0.0 -p 3000`
             - "jobs": `bin/jobs`   (the solid_queue worker)
        6. Use repo_services_logs to confirm they booted; if one crash-loops, read the logs, fix it, and
           repo_services_restart it.

        Do not background anything with `&`. Priority: the web server LISTENING on port 3000.
        DO NOT preview anything in this turn — just get the services running.
      MSG

      drive.call
      dog.ok "the agent asked for secrets (request_secrets)", saw_secrets
      dog.ok "the agent started services (repo_services_start approved)", saw_start
      dog.ok "the turn reached a terminal state", session.reload.done? || session.failed?

      web = worktree.service_runs.reload.find_by(name: "web")
      saved_web = -> { Rbrun::RepoService.for_tenant(tenant).for_repo(repo).find_by(name: "web") }
      dog.ok "the web service is running", web&.status_running?
      # THE POINT: a service is a process inside the box. Running it exposes NOTHING.
      dog.ok "STARTING DID NOT EXPOSE IT — no preview url", web.present? && web.url.blank?
      dog.ok "…and it is not declared previewed", !saved_web.call&.previewed?

      # ── PHASE 2: previewing is a SEPARATE, explicit decision. ──────────────────────────────────────
      dog.header "phase 2 — a second turn asks the agent to preview it"
      session.run_turn("Now make the web service previewable so I can open it in my browser. Use the preview tool.")
      drive.call
      previewed = session.messages.where(event_type: "tool_use").any? { |m| m.payload["name"] == "preview_service" }
      web = worktree.service_runs.reload.find_by(name: "web")
      dog.ok "the agent called preview_service", previewed
      dog.ok "PREVIEWING RESOLVED A URL", web&.url.present?
      dog.ok "…and the declaration is recorded on the saved definition", !!saved_web.call&.previewed?
      dog.ok "the service is still running (preview did not disturb it)", web&.status_running?

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

      # ── the preview the AGENT resolved actually reaches the running app ────────────────────────────
      # The token is header-only (a browser tab can't send it), so that is how we verify reachability
      # here; the URL we hand a human is the bare one, which their own provider session authenticates.
      dog.header "the resolved preview reaches the live app"
      require "faraday"
      require "async/http/faraday"
      if web&.url.present?
        conn = Faraday.new { |f| f.adapter :async_http }
        status = begin
          conn.get(web.url) { |r| r.headers["x-daytona-preview-token"] = web.token if web.token.present? }.status
        rescue StandardError => e
          "err:#{e.class}"
        end
        dog.info "GET preview url (token header)", status.inspect
        dog.ok "the live Rails app answers 200 through the preview", status == 200

        anon = begin
          conn.get(web.url).status
        rescue StandardError
          nil
        end
        dog.info "anonymous (no token)", anon.inspect
        dog.ok "the box is NOT publicly open (anonymous is not served)", anon != 200

        puts "\n╔══════════════════════════════════════════════════════════════════"
        puts "║  OPEN THIS IN YOUR BROWSER TO VALIDATE (box auto-stops in ~5 min):"
        puts "║  #{web.url}"
        puts "╚══════════════════════════════════════════════════════════════════\n"
      else
        dog.ok "a preview url was resolved", false
        dog.info "next", "the agent did not preview the web service — check the phase 2 transcript"
      end
    ensure
      # KEEP THE BOX ALIVE so the printed preview URL actually works — Daytona auto-stops it after 5
      # idle minutes (AUTO_STOP_MINUTES), which is the validation window. No manual destroy.
      dog.info "sandbox", "left running for validation (auto-stops in ~5 min)"
    end
  end
end
