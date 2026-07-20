# frozen_string_literal: true

require "net/http"
require_relative "support"

# Repo services on the LOCAL sandbox — real processes, real HTTP, real secret injection, offline. Drives
# the tool contract directly (the agent's own interface) on a real Local box: no LLM, deterministic. The
# real-LLM + Daytona + preview-token gate is the separate preview_daytona scenario.
#
# Proves: request_secrets storage + KEYS-ONLY recap, secret injection into a service's env,
# repo_services_start (idempotent) launching an HTTP service (localhost preview) + a secret-echo service,
# the live app actually serving, logs (the debug primitive), restart, and stop.
#
#   bin/rails app:dogfood:repo_services_local
namespace :dogfood do
  desc "Repo services on the local sandbox (offline): start/logs/restart/stop, secret injection, localhost preview"
  task repo_services_local: :environment do
    dog = Rbrun::Dogfood

    Rbrun.configure { |c| c.sandbox_provider = { default: :local, local: {} } }

    repo = "rbdotrun/dogfood-local"
    # Repo-scoped rows outlive a worktree — clean prior runs so the dogfood is idempotent.
    Rbrun::RepoSecret.for_tenant("rbrun").for_repo(repo).delete_all
    Rbrun::RepoService.for_tenant("rbrun").for_repo(repo).delete_all

    worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: repo)
    session  = worktree.sessions.create!
    services = [
      { "name" => "web", "command" => "ruby -run -e httpd -- . -p 8087", "port" => 8087 },
      { "name" => "env", "command" => "sh -c 'echo SECRET_SEEN=$MY_SECRET; sleep 60'" }
    ]

    begin
      dog.header "secrets: the value is stored + injected, never surfaced by the tool"
      spec = Rbrun::SecretsFormSpec.new("secrets" => [ { "key" => "MY_SECRET", "required" => true } ])
      Rbrun::RepoSecret.find_or_create_by!(tenant: worktree.tenant, repo: worktree.repo, key: "MY_SECRET") { |s| s.value = "hunter2" }
      recap = spec.stored_recap(%w[MY_SECRET])
      dog.ok "the resume recap names the KEY, never the value", recap.include?("MY_SECRET") && !recap.include?("hunter2")

      dog.header "repo_services_start: launch an HTTP service + a secret-echo service"
      Rbrun::Tools::RepoServicesStart.in_session(session).execute(services: services)
      web = worktree.service_runs.find_by(name: "web")
      dog.ok "web is running", web.status_running?
      dog.ok "web resolved a localhost preview url (Local capability)", web.url == "http://localhost:8087"
      dog.ok "web is previewable", web.previewable?
      dog.ok "the secret-echo service has no port ⇒ not previewable", !worktree.service_runs.find_by(name: "env").previewable?

      sleep 1.5
      resp = begin
        Net::HTTP.get_response(URI("http://localhost:8087"))
      rescue StandardError
        nil
      end
      dog.ok "the live app actually serves over the preview port", resp&.code == "200"

      dog.header "logs: the debug primitive shows real output + proves secret injection"
      env_logs = Rbrun::Tools::RepoServicesLogs.in_session(session).execute(name: "env").dig("data", "logs")
      dog.info "env logs", env_logs.to_s.squish[0, 80]
      dog.ok "the injected secret reached the service's environment", env_logs.to_s.include?("SECRET_SEEN=hunter2")

      dog.header "status: the agent can see what's running"
      status = Rbrun::Tools::RepoServicesStatus.in_session(session).execute.dig("data", "services")
      dog.ok "status lists both services running", status.map { |s| s["status"] }.uniq == [ "running" ] && status.size == 2

      dog.header "restart + idempotent start + stop"
      Rbrun::Tools::RepoServicesRestart.in_session(session).execute(name: "web")
      dog.ok "web is still a single, running row after restart",
             worktree.service_runs.where(name: "web").count == 1 && worktree.service_runs.find_by(name: "web").status_running?

      before = worktree.service_runs.count
      Rbrun::Tools::RepoServicesStart.in_session(session).execute(services: services)
      dog.ok "a second start is idempotent (no duplicate runs)", worktree.service_runs.count == before

      Rbrun::Tools::RepoServicesStop.in_session(session).execute
      dog.ok "stop flips every service to stopped", worktree.service_runs.reload.all?(&:status_stopped?)

      dog.header "the repo's services were saved for reuse"
      saved = Rbrun::RepoService.for_tenant(worktree.tenant).for_repo(worktree.repo).map(&:name).sort
      dog.ok "web + env saved as the repo's services", saved == %w[env web]
    ensure
      worktree.sandbox.destroy!
      worktree.destroy!
      Rbrun::RepoSecret.for_tenant("rbrun").for_repo(repo).delete_all
      Rbrun::RepoService.for_tenant("rbrun").for_repo(repo).delete_all
    end
  end
end
