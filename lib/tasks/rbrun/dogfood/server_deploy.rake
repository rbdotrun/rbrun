# frozen_string_literal: true

require_relative "support"

# One REAL deploy against Hetzner + Cloudflare + our container registry: provision a box, point DNS, and
# deploy a tiny app with Kamal's LOCAL builder — then PROVE the live URL. On success it LEAVES THE
# DEPLOYMENT UP and prints the clickable link (that link is the proof — user-directed: do NOT reap on
# success). Only a FAILURE reaps, so a broken run leaves nothing behind. Teardown is validated separately
# (app:dogfood:server_teardown). Never variabilized (invariant #6).
#
#   bin/rails app:dogfood:server_deploy   (.env: HETZNER_API_TOKEN, CLOUDFLARE_*, KAMAL_REGISTRY_*, RBRUN_PREVIEW_DOMAIN)
namespace :dogfood do
  desc "Server deploy: provision -> dns -> kamal deploy a tiny app, prove the live URL (no reap on success)"
  task server_deploy: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    require "tmpdir"
    require "fileutils"
    require "net/http"
    require "sshkey"

    %w[HETZNER_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_ZONE_ID KAMAL_REGISTRY_SERVER KAMAL_REGISTRY_USERNAME
       KAMAL_REGISTRY_PASSWORD RBRUN_PREVIEW_DOMAIN].each { |k| abort "Missing .env #{k}" if ENV[k].to_s.empty? }

    domain   = ENV["RBRUN_PREVIEW_DOMAIN"]
    reg_user = ENV["KAMAL_REGISTRY_USERNAME"]
    name = "rbrun-dogfood"
    host = "dogfood.#{domain}"

    Rbrun.configure do |c|
      c.server_provider = { default: :kamal_hetzner,
        kamal_hetzner: { hcloud_token: ENV["HETZNER_API_TOKEN"],
                         registry: { server: ENV["KAMAL_REGISTRY_SERVER"], username: reg_user,
                                     password: ENV["KAMAL_REGISTRY_PASSWORD"] } } }
      c.dns_provider = { default: :cloudflare,
                         cloudflare: { api_token: ENV["CLOUDFLARE_API_KEY"], zone_id: ENV["CLOUDFLARE_ZONE_ID"] } }
    end
    Rbrun.config.preview_domain = domain

    # Persist the keypair so a re-run reuses the SAME key the box was created with (a fresh key each run
    # would mismatch an existing box's attached key and break SSH). tmp/ is gitignored.
    pub, priv = dogfood_keypair(name)
    server = Rbrun.server
    dns    = Rbrun.dns

    begin
      dog.header "provision (find-or-create the box)"
      # No cloud-init for Docker — Kamal 2 auto-installs Docker on the host during deploy (a cloud-init
      # apt run would just race Kamal's).
      node = server.create_server(name: name, type: "cx23", region: "fsn1", image: "ubuntu-24.04",
                                  ssh_public_key: pub, labels: { "rbrun-dogfood" => "1" })
      dog.ok "server running with a public ip", !node.ip.to_s.empty?
      dog.info "ip", node.ip

      dog.header "dns (A record -> box)"
      rec = dns.upsert(name: host, type: "A", content: node.ip)
      dog.ok "#{rec.name} -> #{rec.content}", rec.content == node.ip

      dog.header "deploy (kamal local builder)"
      Dir.mktmpdir("rbrun-dogfood-") do |dir|
        write_dogfood_app!(dir, name: name, host: host, reg_user: reg_user, reg_server: ENV["KAMAL_REGISTRY_SERVER"])
        result = server.deploy(work_dir: dir, host: host, server_ip: node.ip, ssh_private_key: priv)
        puts result.output.to_s.lines.last(25).join
        dog.ok "kamal deploy succeeded", result.ok
        raise "deploy failed" unless result.ok
      end

      dog.header "prove the live URL"
      live = poll_https_200("https://#{host}", tries: 40)
      dog.ok "https://#{host} serves 200 over HTTPS", live
      puts "\n🔗  LIVE:  https://#{host}\n\n"
      dog.info "left UP on purpose", "validate teardown with:  bin/rails app:dogfood:server_teardown"
      raise "URL not live yet" unless live
    rescue StandardError => e
      warn "‼️  #{e.class}: #{e.message}"
      warn "reaping (failure path only)…"
      server.destroy_server(name: name)
      dns.remove(name: host, type: "A")
      raise
    end
  end
end

# A persisted RSA keypair for the dogfood (generated once, reused across runs) so an existing box's key
# always matches the private key we deploy with. tmp/ is gitignored.
def dogfood_keypair(name)
  require "sshkey"
  dir = Rbrun::Engine.root.join("tmp")
  FileUtils.mkdir_p(dir)
  priv_path = dir.join("dogfood_id_rsa")
  pub_path  = dir.join("dogfood_id_rsa.pub")
  unless File.exist?(priv_path) && File.exist?(pub_path)
    key = SSHKey.generate(type: "RSA", bits: 4096, comment: name)
    File.write(priv_path, key.private_key)
    File.write(pub_path, key.ssh_public_key)
    File.chmod(0o600, priv_path)
  end
  [ File.read(pub_path), File.read(priv_path) ]
end

# A tiny always-deployable app: busybox httpd serving one HTML page on :3000.
def write_dogfood_app!(dir, name:, host:, reg_user:, reg_server:)
  File.write(File.join(dir, "Dockerfile"), <<~DOCKER)
    FROM busybox
    RUN mkdir -p /www && printf '<h1>rbrun deploy works</h1><p>%s</p>' "#{host}" > /www/index.html
    EXPOSE 3000
    CMD ["httpd", "-f", "-v", "-p", "3000", "-h", "/www"]
  DOCKER
  FileUtils.mkdir_p(File.join(dir, "config"))
  File.write(File.join(dir, "config", "deploy.yml"), <<~YAML)
    service: #{name}
    image: #{reg_user}/#{name}
    servers:
      web:
        - <%= ENV["KAMAL_SERVER_IP"] %>
    proxy:
      ssl: true
      host: #{host}
      app_port: 3000
    registry:
      server: #{reg_server}
      username:
        - KAMAL_REGISTRY_USERNAME
      password:
        - KAMAL_REGISTRY_PASSWORD
    ssh:
      user: root
      keys:
        - <%= ENV["KAMAL_SSH_KEY_FILE"] %>
    builder:
      arch: amd64
  YAML
end

def poll_https_200(url, tries: 40)
  uri = URI(url)
  tries.times do
    begin
      res = Net::HTTP.start(uri.host, 443, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.get("/") }
      return true if res.code.to_i == 200
    rescue StandardError
      # not up yet — cert issuance / container boot
    end
    sleep 10
  end
  false
end
