# frozen_string_literal: true

require_relative "support"

# One REAL deploy of the actual app repo (DOGFOOD_APP_REPO) onto a fresh Hetzner box: provision, point DNS,
# then DeployRunner CLONES the repo, injects our Kamal config (single box + colocated Postgres accessory +
# Let's Encrypt), builds with Kamal's local builder, and deploys — then PROVE the live URL. On success it
# LEAVES THE DEPLOYMENT UP and prints the link (the proof — user-directed: do NOT reap on success). Only a
# FAILURE reaps. Idempotent: a stable dogfood worktree, so re-running redeploys the same box. Teardown is
# validated separately (app:dogfood:server_teardown). Never variabilized (invariant #6).
#
#   bin/rails app:dogfood:server_deploy   (.env: HETZNER_API_TOKEN, CLOUDFLARE_*, KAMAL_REGISTRY_*,
#                                          RBRUN_PREVIEW_DOMAIN, DOGFOOD_APP_REPO, DOGFOOD_APP_MASTER_KEY)
namespace :dogfood do
  desc "Server deploy: clone DOGFOOD_APP_REPO, provision -> dns -> kamal deploy, prove the live URL (no reap on success)"
  task server_deploy: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    require "net/http"
    require "securerandom"

    %w[HETZNER_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_ZONE_ID KAMAL_REGISTRY_SERVER KAMAL_REGISTRY_USERNAME
       KAMAL_REGISTRY_PASSWORD RBRUN_PREVIEW_DOMAIN DOGFOOD_APP_REPO DOGFOOD_APP_MASTER_KEY]
      .each { |k| abort "Missing .env #{k}" if ENV[k].to_s.empty? }

    domain   = ENV["RBRUN_PREVIEW_DOMAIN"]
    repo     = ENV["DOGFOOD_APP_REPO"]
    tenant   = "dogfood"
    host     = "dogfood-app.#{domain}"
    pat      = `gh auth token`.strip
    abort "no gh token — run gh auth login" if pat.empty?

    Rbrun.configure do |c|
      c.github_pat = pat
      c.server_provider = { default: :kamal_hetzner,
        kamal_hetzner: { hcloud_token: ENV["HETZNER_API_TOKEN"],
                         registry: { server: ENV["KAMAL_REGISTRY_SERVER"], username: ENV["KAMAL_REGISTRY_USERNAME"],
                                     password: ENV["KAMAL_REGISTRY_PASSWORD"] } } }
      c.dns_provider = { default: :cloudflare,
                         cloudflare: { api_token: ENV["CLOUDFLARE_API_KEY"], zone_id: ENV["CLOUDFLARE_ZONE_ID"] } }
    end
    Rbrun.config.preview_domain = domain

    # Stable dogfood worktree (idempotent — re-running redeploys the same box, no new worktree/box each run).
    wt = Rbrun::Worktree.for_tenant(tenant).find_by(repo: repo) ||
         Rbrun::Worktree.create!(tenant: tenant, repo: repo, branch: "main")
    target = wt.deploy_target ||
             wt.create_deploy_target!(provider: "kamal_hetzner", server_type: "cx23", region: "fsn1",
                                      image: "ubuntu-24.04", host: host, status: "pending")

    # App secrets the deploy + running container need (same store the preview flow uses).
    Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "RAILS_MASTER_KEY") { |s| s.value = ENV["DOGFOOD_APP_MASTER_KEY"] }
    Rbrun::RepoSecret.find_or_create_by!(tenant: tenant, repo: repo, key: "POSTGRES_PASSWORD") { |s| s.value = SecureRandom.hex(16) }

    name = "rbrun-w#{wt.id}"
    begin
      dog.header "provision (find-or-create the box)"
      public_key, = Rbrun::DeployKeys.ensure!(target)
      node = Rbrun.server.create_server(name: name, type: target.server_type, region: target.region,
                                        image: target.image, ssh_public_key: public_key,
                                        labels: { "rbrun-dogfood" => "1" })
      target.update!(server_id: node.id.to_s, server_ip: node.ip, status: "provisioned")
      dog.ok "server running with a public ip", !node.ip.to_s.empty?
      dog.info "ip", node.ip

      dog.header "dns (A record -> box)"
      rec = Rbrun.dns.upsert(name: host, type: "A", content: node.ip)
      dog.ok "#{rec.name} -> #{rec.content}", rec.content == node.ip

      dog.header "deploy (clone #{repo} @ main -> kamal local builder)"
      result = Rbrun::DeployRunner.new(worktree: wt).run!
      puts result.output.to_s.lines.last(30).join
      dog.ok "kamal deploy succeeded", result.ok
      raise "deploy failed" unless result.ok

      dog.header "prove the live URL"
      live = poll_https_200("https://#{host}", tries: 45)
      dog.ok "https://#{host} serves 200 over HTTPS", live
      puts "\n🔗  LIVE:  https://#{host}\n\n"
      dog.info "left UP on purpose", "validate teardown with:  bin/rails app:dogfood:server_teardown"
      raise "URL not live yet" unless live
    rescue StandardError => e
      warn "‼️  #{e.class}: #{e.message}"
      warn "reaping (failure path only)…"
      Rbrun.server.destroy_server(name: name)
      Rbrun.dns.remove(name: host, type: "A")
      target.update!(status: "failed", server_id: nil, server_ip: nil)
      raise
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
      # not up yet — cert issuance / container boot / migrations
    end
    sleep 10
  end
  false
end
