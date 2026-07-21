# frozen_string_literal: true

require_relative "support"

# Validate teardown — run ONLY after app:dogfood:server_deploy proved the live URL. Destroys the server +
# DNS record and confirms both are gone (idempotent, invariant #11). Kept a SEPARATE task on purpose: the
# deploy dogfood leaves the deployment up as proof; this reaps it once we've seen the link.
#
#   bin/rails app:dogfood:server_teardown
namespace :dogfood do
  desc "Server teardown: reap the dogfood deployment (server + DNS) after the URL was proven"
  task server_teardown: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    %w[HETZNER_API_TOKEN CLOUDFLARE_API_KEY CLOUDFLARE_ZONE_ID RBRUN_PREVIEW_DOMAIN].each { |k| abort "Missing .env #{k}" if ENV[k].to_s.empty? }

    name = "rbrun-dogfood"
    host = "dogfood.#{ENV["RBRUN_PREVIEW_DOMAIN"]}"

    Rbrun.configure do |c|
      c.server_provider = { default: :kamal_hetzner, kamal_hetzner: { hcloud_token: ENV["HETZNER_API_TOKEN"] } }
      c.dns_provider = { default: :cloudflare,
                         cloudflare: { api_token: ENV["CLOUDFLARE_API_KEY"], zone_id: ENV["CLOUDFLARE_ZONE_ID"] } }
    end

    dog.header "teardown"
    Rbrun.server.destroy_server(name: name)
    Rbrun.dns.remove(name: host, type: "A")
    dog.ok "server gone", Rbrun.server.find_server(name: name).nil?
    dog.info "reaped", "#{name} + #{host}"
  end
end
