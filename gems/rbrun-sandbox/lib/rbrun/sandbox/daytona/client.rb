# frozen_string_literal: true

require "json"
require "digest"
require "cgi"
require "faraday"
require "faraday/multipart"
require "async"
require "async/http/faraday"
require "async/http/internet"

module Rbrun
  module Sandbox
    class Daytona
      # The Daytona API, and nothing else — sandboxes, and the files and commands inside them. It
      # knows nothing about sessions/agents/turns; Rbrun::Sandbox::Daytona (the adapter) is one box's
      # contract, this is the wire.
      #
      # FARADAY ON ASYNC-HTTP, and NOT the official `daytona` gem: that gem's Typhoeus → libcurl
      # transport is not fork-safe, and Falcon forks its workers — the first call inside a forked
      # worker deadlocks at 0% CPU forever. Faraday on async-http is pure Ruby and fiber-scheduler
      # friendly. CONSTRUCTED FROM EXPLICIT CREDENTIALS, never the environment.
      class Client
        class Error < StandardError; end

        TOOLBOX = "https://proxy.app.daytona.io/toolbox"
        AUTO_STOP_MINUTES = 5
        START_TIMEOUT = 90
        # A box can vanish while starting (Daytona destroys it server-side mid-start) — a transient
        # failure, not a dead end. Discard it and create a fresh one, bounded. Only vanish is retried:
        # a box STUCK at a state is a real problem (e.g. a bad snapshot), and retrying wastes the timeout.
        CREATE_ATTEMPTS = 3

        # Snapshot defaults — all overridable via config. The agent box is a SELF-BUILT Daytona
        # snapshot, built server-side from a Dockerfile STRING (POST /snapshots), content-addressed by
        # the Dockerfile digest so an unchanged image is reused and any change builds a fresh one.
        # Resources bake ON the snapshot (a snapshot-backed sandbox can't override cpu/memory/disk).
        DEFAULT_SNAPSHOT_NAME  = "rbrun-sandbox"
        DEFAULT_CPU    = 2
        DEFAULT_MEMORY = 4 # GiB
        DEFAULT_DISK   = 3 # GiB
        SNAPSHOT_BUILD_TIMEOUT = 900
        SNAPSHOT_POLL_INTERVAL = 5

        # The agent runner's base: bun (stages + runs client.ts), a shell, and the BASELINE DEV
        # TOOLCHAIN a coding agent needs to do real work in a repo — git, curl, jq, and the GitHub CLI
        # (`gh`) so it can open PRs the normal way instead of hand-rolling REST calls. Baked into the
        # snapshot (content-addressed by this Dockerfile's digest), so every box inherits it and an
        # unchanged image is reused. Hosts that need more (python, Office readers) inject their own via
        # config[:dockerfile].
        DEFAULT_DOCKERFILE = <<~DOCKER
          FROM oven/bun:1-debian
          RUN apt-get update \\
            && apt-get install -y --no-install-recommends git ca-certificates curl gnupg jq \\
            && install -d -m 0755 /usr/share/keyrings \\
            && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \\
            && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \\
            && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \\
            && apt-get update && apt-get install -y --no-install-recommends gh \\
            && useradd -m daytona \\
            && mkdir -p /home/daytona/workspace && chown -R daytona:daytona /home/daytona \\
            && apt-get clean && rm -rf /var/lib/apt/lists/*
          USER daytona
          WORKDIR /home/daytona/workspace
        DOCKER

        attr_reader :api_key

        def initialize(api_key:, api_url:, dockerfile: nil, snapshot_name: nil, cpu: nil, memory: nil, disk: nil)
          @api_key       = api_key
          @api_url       = api_url
          @dockerfile    = dockerfile    || DEFAULT_DOCKERFILE
          @snapshot_name = snapshot_name || DEFAULT_SNAPSHOT_NAME
          @cpu           = cpu    || DEFAULT_CPU
          @memory        = memory || DEFAULT_MEMORY
          @disk          = disk   || DEFAULT_DISK
          @ensured       = {}
          raise Error, "daytona credentials missing (config.api_key)" if @api_key.nil? || @api_key.empty?
        end

        # The box for these labels, up and reachable. LABELS, NOT AN ID — we store nothing; the label
        # is the address. Nothing to go stale, so nothing to heal.
        def find_or_create(labels)
          attempt = 0
          begin
            box = find_by_labels(labels) || create_sandbox(labels)
            return box if box["state"].to_s == "started"

            await_started(box["id"])
          rescue Error => e
            attempt += 1
            raise if attempt >= CREATE_ATTEMPTS || !e.message.include?("vanished while starting")

            sleep attempt # brief backoff; the vanished box 404s, so the retry creates a fresh one
            retry
          end
        end

        # ── snapshot (the box's image, built server-side from config[:dockerfile]) ──────────────
        # Content-addressed tag: a digest of the Dockerfile, so an unchanged image is reused and any
        # change builds a fresh one.
        def snapshot_ref = "#{@snapshot_name}:#{Digest::SHA256.hexdigest(@dockerfile)[0, 16]}"

        # The snapshot every sandbox starts from — built once, lazily, by Daytona from our Dockerfile.
        # Absent (404) → create it (Daytona builds server-side) and wait until active; present → reuse.
        # Memoized per Dockerfile digest.
        def ensure_snapshot
          name = snapshot_ref
          @ensured[name] ||= begin
            create_snapshot(name) if snapshot_state(name).nil?
            await_snapshot_active(name) unless snapshot_state(name) == "active"
            name
          end
        end

        # POST /snapshots with the Dockerfile CONTENT — Daytona builds the image itself, no registry.
        # 409 = a concurrent creator won; the wait in ensure_snapshot still applies.
        def create_snapshot(name)
          post("#{@api_url}/snapshots", body: {
            "name" => name,
            "buildInfo" => { "dockerfileContent" => @dockerfile },
            "cpu" => @cpu, "memory" => @memory, "disk" => @disk
          })
        rescue Error => e
          raise unless e.message.include?("409")
        end

        # The snapshot's state ("active"/"error"/"build_failed"/…), or nil when it doesn't exist (404).
        def snapshot_state(name = snapshot_ref)
          r = conn.get("#{@api_url}/snapshots/#{CGI.escape(name)}")
          return nil if r.status == 404

          ok!(r).body["state"]
        end

        def await_snapshot_active(name)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SNAPSHOT_BUILD_TIMEOUT
          loop do
            state = snapshot_state(name)
            return if state == "active"
            raise Error, "snapshot #{name} entered #{state}" if %w[error build_failed].include?(state)
            raise Error, "snapshot #{name} not active in #{SNAPSHOT_BUILD_TIMEOUT}s (#{state})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep SNAPSHOT_POLL_INTERVAL
          end
        end

        # The box these labels name, or nil. The label index is eventually consistent and lies, so
        # the list DISCOVERS a candidate and `get` (which 404s the instant a box is gone) decides
        # whether it is real. Oldest first, so every later turn agrees which box is the conversation's.
        def find_by_labels(labels)
          body = get("#{@api_url}/sandbox", "labels" => labels.transform_values(&:to_s).to_json)
          items = body.is_a?(Hash) ? body["items"] : body

          candidate =
            Array(items)
              .reject { |s| %w[destroyed destroying error].include?(s["state"].to_s) }
              .min_by { |s| s["createdAt"].to_s }
          return nil unless candidate

          confirm(candidate["id"])
        end

        def await_started(id)
          request_start(id)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_TIMEOUT
          loop do
            box = confirm(id) or raise Error, "sandbox #{id} vanished while starting"
            return box if box["state"].to_s == "started"

            request_start(id) if box["state"].to_s == "stopped"
            raise Error, "sandbox #{id} stuck at #{box["state"]}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 1
          end
        end

        def request_start(id)
          post("#{@api_url}/sandbox/#{id}/start")
        rescue Error => e
          raise unless e.message.include?("409")
        end

        def destroy(id) = request(:delete, "#{@api_url}/sandbox/#{id}", params: { "force" => "true" })

        # ── inside the box ─────────────────────────────────────────────
        def exec(id, command, timeout: 60)
          post("#{TOOLBOX}/#{id}/process/execute", body: { "command" => command, "timeout" => timeout }, timeout: timeout + 15)
        end

        def download(id, path) = request(:get, "#{TOOLBOX}/#{id}/files/download", params: { "path" => path }).body.to_s

        # ── process sessions ───────────────────────────────────────────
        def create_session(id, session_id)
          post("#{TOOLBOX}/#{id}/process/session", body: { "sessionId" => session_id })
        end

        def session_exec(id, session_id, command)
          body = post("#{TOOLBOX}/#{id}/process/session/#{session_id}/exec",
                      body: { "command" => command, "runAsync" => true }, timeout: 30)
          body.is_a?(Hash) ? (body["cmdId"] || body["commandId"] || body["id"]) : body
        end

        def session_input(id, session_id, command_id, data)
          post("#{TOOLBOX}/#{id}/process/session/#{session_id}/command/#{command_id}/input", body: { "data" => data })
        end

        def session_command(id, session_id, command_id)
          get("#{TOOLBOX}/#{id}/process/session/#{session_id}/command/#{command_id}")
        end

        # A SNAPSHOT of the command's output — a plain, non-follow GET that closes immediately. Use this
        # for "show me the logs"; session_logs_follow is only for streaming a run to completion. Following
        # a still-running process never closes its stream, so a follow-based snapshot hangs.
        def session_logs(id, session_id, command_id)
          request(:get, "#{TOOLBOX}/#{id}/process/session/#{session_id}/command/#{command_id}/logs").body.to_s
        end

        # FOLLOW the command's output live. RAW async-http, not Faraday: the Faraday async-http adapter
        # buffers the whole body, so its on_data never fires until the stream closes — a deadlock for a
        # follow that only closes on command exit. `skip` bytes are dropped first (resume offset).
        # Returns total bytes seen; blocks until the stream ends or the block returns truthy.
        def session_logs_follow(id, session_id, command_id, skip: 0, timeout: nil)
          url = "#{TOOLBOX}/#{id}/process/session/#{session_id}/command/#{command_id}/logs?follow=true"
          seen = 0
          Sync do |task|
            internet = Async::HTTP::Internet.new
            read = lambda do
              response = internet.get(url, [ [ "authorization", "Bearer #{@api_key}" ] ])
              while (chunk = response.body&.read)
                bytes = chunk.to_s
                prev = seen
                seen += bytes.bytesize
                if skip.positive? && seen <= skip
                  next
                elsif skip.positive? && prev < skip
                  bytes = bytes.byteslice(skip - prev..) || ""
                end
                next if bytes.empty?

                break if yield(bytes)
              end
            ensure
              response&.close
            end
            begin
              timeout ? task.with_timeout(timeout) { read.call } : read.call
            ensure
              internet&.close
            end
          end
          seen
        end

        def create_folder(id, path, mode = "755")
          request(:post, "#{TOOLBOX}/#{id}/files/folder", params: { "path" => path, "mode" => mode })
        end

        # `source` is a local path or an IO. Multipart, field name `file`, path as a query param.
        def upload(id, path, source)
          io = source.respond_to?(:read) ? source : File.open(source, "rb")
          part = Faraday::Multipart::FilePart.new(io, "application/octet-stream", File.basename(path))
          request(
            :post,
            "#{TOOLBOX}/#{id}/files/upload",
            params: { "path" => path },
            body: { "file" => part },
            timeout: 120
          )
        ensure
          io.close if io && !source.respond_to?(:read)
        end

        private

        def confirm(id)
          r = conn.get("#{@api_url}/sandbox/#{id}")
          return nil if r.status == 404

          ok!(r).body
        end

        def create_sandbox(labels)
          post(
            "#{@api_url}/sandbox",
            body: {
              "labels" => labels.transform_values(&:to_s),
              "autoStopInterval" => AUTO_STOP_MINUTES,
              # Start from the self-built snapshot (config[:dockerfile]), built server-side on first
              # use. Resources are baked on the snapshot — the API refuses cpu/memory/disk here.
              "snapshot" => ensure_snapshot
            },
            timeout: 120
          )
        end

        def get(url, params = {}) = request(:get, url, params: params).body

        def post(url, body: nil, params: {}, timeout: 60) = request(:post, url, body: body, params: params, timeout: timeout).body

        def request(method, url, params: {}, body: nil, timeout: 60)
          response = conn.public_send(method, url) do |req|
            req.options.timeout = timeout
            req.params.update(params)
            next if body.nil?

            if body.is_a?(Hash) && body.values.any? { |v| v.is_a?(Faraday::Multipart::FilePart) }
              req.body = body
            else
              req.headers["Content-Type"] = "application/json"
              req.body = body.to_json
            end
          end
          ok!(response)
        end

        def ok!(response)
          return response if response.success?

          raise Error, "#{response.env.method.to_s.upcase} #{response.env.url.path} → #{response.status}: #{response.body.to_s[0, 200]}"
        end

        def conn
          @conn ||= Faraday.new do |f|
            f.request :multipart
            f.response :json, content_type: /\bjson/
            f.headers["Authorization"] = "Bearer #{@api_key}"
            f.options.open_timeout = 15
            f.adapter :async_http
          end
        end
      end
    end
  end
end
