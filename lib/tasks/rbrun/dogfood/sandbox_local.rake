# frozen_string_literal: true

require "rbrun/sandbox"
require_relative "support"

# Phase 2 dogfood — the LOCAL sandbox, for real (real processes, real files, offline). Exercises the
# full contract end to end: create → upload → exec → glob → a streaming process session → read → destroy.
#
#   bin/rails app:dogfood:sandbox_local

namespace :dogfood do
  desc "Phase 2: the local sandbox runs the full exec/file/session contract for real (offline)"
  task :sandbox_local do
    dog = Rbrun::Dogfood
    box = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { dogfood: "local" })

    dog.header "files"
    box.write("uploads/hello.txt", "bonjour")
    dog.ok "wrote + read back a file", box.read("uploads/hello.txt") == "bonjour"
    dog.ok "exist? is true for a written path", box.exist?("uploads/hello.txt")
    box.write("sub/nested.txt", "x")
    dog.ok "glob lists files relative + sorted", box.glob(".") == [ "sub/nested.txt", "uploads/hello.txt" ]

    dog.header "exec"
    result = box.exec("echo streamed")
    dog.ok "exec returns a successful ExecResult", result.success? && result.stdout == "streamed\n"

    dog.header "process session (streamed stdin→stdout)"
    box.session_create("s")
    cmd = box.session_exec("s", "cat") # echoes stdin, exits on stdin close
    box.session_input("s", cmd, "ping\n")
    seen = String.new
    bytes = box.session_logs_follow("s", cmd, skip: 0, timeout: 5) { |c| seen << c; seen.include?("ping") }
    dog.ok "session streamed our stdin back on stdout", seen.include?("ping")
    dog.ok "follow reported a positive byte offset", bytes.positive?

    dog.header "teardown"
    root = box.workspace
    box.destroy!
    dog.ok "destroy! removed the box directory", !File.exist?(root)
  end
end
