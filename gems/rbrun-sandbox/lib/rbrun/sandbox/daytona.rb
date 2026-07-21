# frozen_string_literal: true

require "shellwords"
require "tempfile"
require "async"

module Rbrun
  module Sandbox
    # ONE box's contract, Daytona-backed. Found by LABEL, never a stored id (see Client#find_or_create).
    # A path is a path inside this sandbox, always. Normalizes the wire's `{ "exitCode", "result" }`
    # into ExecResult so callers speak one contract across adapters.
    class Daytona
      ROOT = "/home/daytona"
      WORKSPACE = File.join(ROOT, "workspace")

      def initialize(config: {}, labels: {}, client: nil)
        @labels = labels
        @client = client || Client.new(
          api_key:       config[:api_key],
          api_url:       config[:api_url],
          dockerfile:    config[:dockerfile],
          snapshot_name: config[:snapshot_name],
          cpu:           config[:cpu],
          memory:        config[:memory],
          disk:          config[:disk]
        )
      rescue Client::Error => e
        raise Error, e.message
      end

      def id = sandbox["id"]

      def workspace = WORKSPACE

      def exec(command, timeout: 60)
        raw = @client.exec(id, command, timeout: timeout)
        ExecResult.new(exit_code: raw["exitCode"].to_i, stdout: raw["result"].to_s, stderr: "")
      end

      def exec!(command, timeout: 60)
        result = exec(command, timeout: timeout)
        return result if result.success?

        raise Error, "#{command.inspect} exited #{result.exit_code}: #{result.stdout.to_s.lines.last(5).join}"
      end

      def write(remote_path, content)
        @client.create_folder(id, File.dirname(remote_path))
        Tempfile.create("rbrun-upload") do |tmp|
          tmp.binmode
          tmp.write(content.to_s)
          tmp.flush
          @client.upload(id, remote_path, tmp.path)
        end
      end

      def read(remote_path) = @client.download(id, remote_path)

      def exist?(remote_path) = exec("test -e #{Shellwords.escape(remote_path)}").success?

      def create_folder(path, mode = "755") = @client.create_folder(id, path, mode)

      def upload(files)
        files.map { |f| File.dirname(f.destination) }.uniq.each { |d| @client.create_folder(id, d) }
        files.each { |f| @client.upload(id, f.destination, f.source) }
      end

      def glob(dir)
        exec("cd #{Shellwords.escape(dir)} && find . -type f | sed 's|^\\./||' | sort")
          .stdout.to_s.lines.map(&:strip).reject(&:empty?)
      end

      def destroy!
        @client.destroy(id)
        @sandbox = nil
      end

      # ── process sessions (delegate, injecting our own box id) ──────────
      # IDEMPOTENT BY CONTRACT (Local uses `||=`): a 409 means the session is already there, which is
      # success for a caller that just wants it to exist. Without this, relaunching a service under its
      # own deterministic session name (restart, or an idempotent re-start) fails forever on Daytona.
      def session_create(session_id)
        @client.create_session(id, session_id)
      rescue Client::Error => e
        raise Error, e.message unless e.message.include?("409")

        nil
      end
      def session_exec(session_id, command) = @client.session_exec(id, session_id, command)
      # Snapshot of a command's output (non-follow) — safe on a still-running process.
      def session_logs(session_id, cmd_id) = @client.session_logs(id, session_id, cmd_id)
      def session_input(session_id, cmd_id, data) = @client.session_input(id, session_id, cmd_id, data)
      def session_command(session_id, cmd_id) = @client.session_command(id, session_id, cmd_id)

      def session_logs_follow(session_id, cmd_id, skip: 0, timeout: nil, &block)
        @client.session_logs_follow(id, session_id, cmd_id, skip: skip, timeout: timeout, &block)
      rescue Async::TimeoutError => e
        raise TimeoutError, "session #{session_id}/#{cmd_id} follow timed out (#{e.message})"
      end

      private

      # Resolved once per instance (the caller memoizes the adapter), so one turn is one lookup.
      def sandbox = @sandbox ||= @client.find_or_create(@labels)
    end
  end
end

require "rbrun/sandbox/daytona/client"
