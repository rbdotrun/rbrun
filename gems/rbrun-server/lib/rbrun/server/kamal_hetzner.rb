# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "faraday"
require "async/http/faraday"

module Rbrun
  module Server
    # Hetzner Cloud provisioning + Kamal deploy. FARADAY ON ASYNC-HTTP (fork-safe under Falcon), built from
    # EXPLICIT credentials, never the environment. Validates its own config and fails fast. create/destroy
    # are idempotent by server name so re-running converges (invariant #11). Never uses the hcloud CLI (which
    # also sidesteps its v1.51 SIGSEGV/capacity crashes).
    #
    # SSH keys are NOT config — they arrive per call (the engine generates + stores a keypair per
    # deployment). create_server uploads the given public key (attached by the server's own name); deploy /
    # app_logs authenticate with the given private key.
    class KamalHetzner < Base
      API = "https://api.hetzner.cloud/v1"
      # Hetzner returns 412 "error during placement" when a location is out of capacity for the type — roll
      # over to another location instead of failing the whole provision.
      FALLBACK_LOCATIONS = %w[fsn1 nbg1 hel1].freeze
      # The box is provisioned with a non-root `deploy` user (our cloud-init), so kamal + the agent SSH in
      # as `deploy`, never root. root login + password auth are disabled.
      SSH_USER = "deploy"

      def initialize(config: {}, poll_interval: 2, poll_attempts: 60)
        @token    = config[:hcloud_token]
        @registry = config[:registry] || {}
        @poll_interval = poll_interval
        @poll_attempts = poll_attempts
        raise Error, "kamal_hetzner: hcloud_token missing" if @token.to_s.empty?
      end

      def find_server(name:)
        node_from(Array(request(:get, "/servers", nil, { "name" => name })["servers"]).first)
      end

      def list_servers(label: nil)
        params = {}
        params["label_selector"] = label if label
        Array(request(:get, "/servers", nil, params)["servers"]).map { |s| node_from(s) }
      end

      def create_server(name:, type:, region:, image:, ssh_public_key:, user_data: nil, labels: {})
        existing = find_server(name: name)
        return await_ready(existing) if existing

        key_name  = ensure_ssh_key(name: name, public_key: ssh_public_key)
        locations = [ region, *FALLBACK_LOCATIONS ].uniq
        last_error = nil
        locations.each do |loc|
          body = { "name" => name, "server_type" => type, "image" => image, "location" => loc,
                   "ssh_keys" => [ key_name ], "labels" => labels,
                   "user_data" => (user_data || cloud_init(ssh_public_key)) }
          begin
            return await_ready(node_from(request(:post, "/servers", body).fetch("server")))
          rescue Error => e
            raise unless e.message.match?(/placement|resource_unavailable|412/)

            last_error = e # this location is out of capacity — try the next
          end
        end
        raise last_error
      end

      def destroy_server(name:)
        existing = find_server(name: name)
        return false unless existing

        request(:delete, "/servers/#{existing.id}")
        true
      end

      # Deploy the app in work_dir onto the server via Kamal's LOCAL builder. The generated deploy.yml reads
      # the server IP + registry creds from the child env; the ssh private key authenticates the deploy.
      def deploy(work_dir:, host:, server_ip:, ssh_private_key:, env: {})
        forget_host_key(server_ip)
        with_key_file(ssh_private_key) do |key_path|
          child = kamal_env(server_ip: server_ip, key_path: key_path, host: host).merge(env.transform_keys(&:to_s))
          output, ok = run_kamal([ "deploy" ], env: child, chdir: work_dir)
          DeployResult.new(ok: ok, output: output)
        end
      end

      # The deployed app's container logs from the server, via Kamal. @return [String]
      def app_logs(work_dir:, server_ip:, ssh_private_key:, tail: 100)
        forget_host_key(server_ip)
        with_key_file(ssh_private_key) do |key_path|
          output, _ok = run_kamal([ "app", "logs", "-n", tail.to_s ],
                                  env: kamal_env(server_ip: server_ip, key_path: key_path), chdir: work_dir)
          output
        end
      end

      private

      # Kamal reads its SSH key from deploy.yml (ssh.keys), not an env var — so materialize the private key
      # to a 0600 temp file and expose its path as KAMAL_SSH_KEY_FILE; the generated deploy.yml points at it.
      # The file lives only for the command's duration.
      def with_key_file(private_key)
        f = Tempfile.new("rbrun-deploy-key")
        f.write(private_key.to_s)
        f.close
        File.chmod(0o600, f.path)
        yield f.path
      ensure
        f&.unlink
      end

      def kamal_env(server_ip:, key_path:, host: nil)
        env = {
          "KAMAL_REGISTRY_SERVER"   => @registry[:server].to_s,
          "KAMAL_REGISTRY_USERNAME" => @registry[:username].to_s,
          "KAMAL_REGISTRY_PASSWORD" => @registry[:password].to_s,
          "KAMAL_SERVER_IP"         => server_ip.to_s,
          "KAMAL_SSH_USER"          => SSH_USER,
          "KAMAL_SSH_KEY_FILE"      => key_path.to_s
        }
        env["KAMAL_HOST"] = host.to_s if host
        env
      end

      # Cloud-init: a non-root `deploy` user (NOPASSWD sudo + our key), Docker installed and deploy added to
      # the docker group, root login + password auth disabled. So kamal (and the agent) SSH in as `deploy`
      # with our key, run Docker without sudo, and root is never exposed.
      def cloud_init(ssh_public_key)
        <<~YAML
          #cloud-config
          users:
            - name: #{SSH_USER}
              groups: [sudo]
              shell: /bin/bash
              sudo: "ALL=(ALL) NOPASSWD:ALL"
              ssh_authorized_keys:
                - #{ssh_public_key.to_s.strip}
          ssh_pwauth: false
          disable_root: true
          package_update: true
          packages:
            - docker.io
          runcmd:
            - systemctl enable --now docker
            - usermod -aG docker #{SSH_USER}
        YAML
      end

      def run_kamal(argv, env:, chdir:)
        out, status = Open3.capture2e(env, "kamal", *argv, chdir: chdir)
        [ out, status.success? ]
      end

      # Hetzner recycles IPs: a box we tore down and a freshly-provisioned one can land on the same IP, so a
      # known_hosts entry from a PRIOR deploy makes kamal's Net::SSH raise HostKeyMismatch (it accepts new
      # hosts but rejects changed keys). The box is ephemeral and provisioned by us seconds ago, so forget any
      # prior key for this IP — the fresh key is then accepted as a new host. This mirrors the
      # StrictHostKeyChecking=no our own SSH (DeployRunner#ssh_ready?/exec_on_box) already uses; kamal is the
      # one deploy path that verifies. Best-effort: a missing known_hosts / no ssh-keygen must not block deploy.
      def forget_host_key(server_ip)
        return if server_ip.to_s.empty?

        Open3.capture2e("ssh-keygen", "-R", server_ip.to_s)
      rescue StandardError
        nil
      end

      # Find-or-create the server's ssh key in the project (keyed by the server name, so each deployment has
      # its own). Returns the key name to attach. Idempotent — a re-run reuses the existing key.
      def ensure_ssh_key(name:, public_key:)
        found = Array(request(:get, "/ssh_keys", nil, { "name" => name })["ssh_keys"]).first
        return found["name"] if found

        request(:post, "/ssh_keys", { "name" => name, "public_key" => public_key }).dig("ssh_key", "name") || name
      rescue Error
        name # already present by fingerprint (Hetzner uniqueness) — attach by the same name
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
