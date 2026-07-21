# frozen_string_literal: true

require "json"
require "faraday"
require "async/http/faraday"

module Rbrun
  module Server
    # Hetzner Cloud provisioning + Kamal deploy. FARADAY ON ASYNC-HTTP (fork-safe under Falcon), built from
    # EXPLICIT credentials, never the environment. Validates its own config and fails fast. create/destroy
    # are idempotent by server name so re-running converges (invariant #11). Never uses the hcloud CLI (which
    # also sidesteps its v1.51 SIGSEGV/capacity crashes).
    class KamalHetzner < Base
      API = "https://api.hetzner.cloud/v1"
      SSH_KEY_NAME = "rbrun"

      def initialize(config: {}, poll_interval: 2, poll_attempts: 60)
        @token    = config[:hcloud_token]
        @ssh_pub  = config[:ssh_public_key]
        @ssh_key  = config[:ssh_private_key]
        @registry = config[:registry] || {}
        @poll_interval = poll_interval
        @poll_attempts = poll_attempts
        raise Error, "kamal_hetzner: hcloud_token missing"   if @token.to_s.empty?
        raise Error, "kamal_hetzner: ssh_public_key missing" if @ssh_pub.to_s.empty?
        raise Error, "kamal_hetzner: ssh_private_key missing" if @ssh_key.to_s.empty?
      end

      def find_server(name:)
        node_from(Array(request(:get, "/servers", nil, { "name" => name })["servers"]).first)
      end

      def list_servers(label: nil)
        params = {}
        params["label_selector"] = label if label
        Array(request(:get, "/servers", nil, params)["servers"]).map { |s| node_from(s) }
      end

      def create_server(name:, type:, region:, image:, ssh_keys: [], user_data: nil, labels: {})
        existing = find_server(name: name)
        return await_ready(existing) if existing

        keys = ssh_keys.empty? ? [ ensure_ssh_key ] : ssh_keys
        body = { "name" => name, "server_type" => type, "image" => image, "location" => region,
                 "ssh_keys" => keys, "labels" => labels }
        body["user_data"] = user_data if user_data
        created = node_from(request(:post, "/servers", body).fetch("server"))
        await_ready(created)
      end

      def destroy_server(name:)
        existing = find_server(name: name)
        return false unless existing

        request(:delete, "/servers/#{existing.id}")
        true
      end

      private

      # Find-or-create our SSH public key in the project (by name), so the box is reachable for the Kamal
      # deploy. Returns the key name to attach. Idempotent — a re-run reuses the existing key.
      def ensure_ssh_key
        found = Array(request(:get, "/ssh_keys", nil, { "name" => SSH_KEY_NAME })["ssh_keys"]).first
        return found["name"] if found

        created = request(:post, "/ssh_keys", { "name" => SSH_KEY_NAME, "public_key" => @ssh_pub })
        created.dig("ssh_key", "name") || SSH_KEY_NAME
      rescue Error
        SSH_KEY_NAME # the key already exists by fingerprint (Hetzner uniqueness) — attach by the same name
      end

      def await_ready(node)
        attempts = 0
        while node && (node.status != "running" || node.ip.to_s.empty?)
          attempts += 1
          break if attempts > @poll_attempts

          sleep @poll_interval if @poll_interval.positive?
          node = node_from(request(:get, "/servers/#{node.id}").fetch("server"))
        end
        node
      end

      def node_from(raw)
        return nil unless raw

        Node.new(id: raw["id"], name: raw["name"], status: raw["status"],
                 ip: raw.dig("public_net", "ipv4", "ip"),
                 region: raw.dig("datacenter", "location", "name"))
      end

      def request(method, path, body = nil, params = {})
        response = conn.public_send(method, "#{API}#{path}") do |req|
          req.params.update(params) if params.any?
          next if body.nil?

          req.headers["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        parsed = response.body.is_a?(Hash) ? response.body : (JSON.parse(response.body.to_s) rescue {})
        return parsed if response.success?

        msg = parsed.dig("error", "message") || response.status
        raise Error, "kamal_hetzner: #{method.to_s.upcase} #{path} → #{response.status} #{msg}"
      end

      def conn
        @conn ||= Faraday.new do |f|
          f.response :json, content_type: /\bjson/
          f.headers["Authorization"] = "Bearer #{@token}"
          f.options.open_timeout = 15
          f.options.timeout = 30
          f.adapter :async_http
        end
      end
    end
  end
end
