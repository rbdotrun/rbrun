# frozen_string_literal: true

require "open3"
require "fileutils"
require "tempfile"
require "timeout"

module Rbrun
  module Sandbox
    # Runs a "sandbox" as a plain directory on the local host — real processes, real files, no cloud.
    # The offline executor: it runs the actual agent loop (bun client.ts) for dogfood + CI without
    # provisioning Daytona. One box == one directory under `config[:root]`, addressed by labels.
    class Local
      ROOT = "workspace"

      def initialize(config: {}, labels: {})
        base   = config[:root] || File.join(Dir.tmpdir, "rbrun-sandboxes")
        @root  = File.join(base, slugify(labels))
        @sessions = {}
        FileUtils.mkdir_p(workspace)
      end

      def id = @root

      # The box's working root (parallels Daytona's /home/daytona/workspace).
      def workspace = File.join(@root, ROOT)

      def exec(command, timeout: 60)
        Timeout.timeout(timeout) do
          out, err, status = Open3.capture3(command, chdir: workspace)
          ExecResult.new(exit_code: status.exitstatus, stdout: out, stderr: err)
        end
      end

      def exec!(command, timeout: 60)
        result = exec(command, timeout: timeout)
        return result if result.success?

        raise Error, "#{command.inspect} exited #{result.exit_code}: #{result.stderr.to_s.lines.last(5).join}"
      end

      # popen2e — combined stdout+stderr on one pipe, matching Daytona's merged session stream.
      def exec_stream(command, timeout: 600, &block)
        buf = String.new
        line_buffer = LineBuffer.new(->(line) { buf << line; block&.call(line) })
        Timeout.timeout(timeout) do
          Open3.popen2e(command, chdir: workspace) do |_stdin, out_err, wait_thr|
            until out_err.eof?
              line_buffer.feed(out_err.readpartial(4096))
            end
            line_buffer.flush
            ExecResult.new(exit_code: wait_thr.value.exitstatus, stdout: buf, stderr: "")
          end
        end
      end

      def write(remote_path, content)
        path = absolute(remote_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content.to_s)
      end

      def read(remote_path) = File.binread(absolute(remote_path))

      def exist?(remote_path) = File.exist?(absolute(remote_path))

      def create_folder(path, _mode = "755") = FileUtils.mkdir_p(absolute(path))

      def upload(files)
        files.each do |f|
          dest = absolute(f.destination)
          FileUtils.mkdir_p(File.dirname(dest))
          content = f.source.respond_to?(:read) ? f.source.read : File.binread(f.source)
          File.binwrite(dest, content)
        end
      end

      def glob(dir)
        base = absolute(dir)
        Dir.glob("**/*", base: base).select { |rel| File.file?(File.join(base, rel)) }.sort
      end

      def destroy!
        FileUtils.rm_rf(@root)
        @sessions.clear
        nil
      end

      private

      def absolute(path)
        path.start_with?(@root) ? path : File.join(workspace, path)
      end

      def slugify(labels)
        return "default" if labels.nil? || labels.empty?

        labels.map { |k, v| "#{k}-#{v}" }.join("_").gsub(/[^a-zA-Z0-9_\-]/, "-")
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
