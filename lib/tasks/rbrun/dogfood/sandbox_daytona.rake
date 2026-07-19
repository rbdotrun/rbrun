# frozen_string_literal: true

require "rbrun/sandbox"
require_relative "support"

# Phase 2 dogfood — the DAYTONA sandbox, for real (live cloud box). Same contract as sandbox_local,
# against a real Daytona sandbox. Credentials come from .env (a secret store, not a scenario variable:
# dogfood is never parameterized).
#
#   bin/rails app:dogfood:sandbox_daytona

namespace :dogfood do
  desc "Phase 2: the daytona sandbox runs the full contract for real (live cloud box)"
  task :sandbox_daytona do
    dog = Rbrun::Dogfood
    dog.load_env!
    api_key = ENV["DAYTONA_API_KEY"].to_s
    api_url = ENV["DAYTONA_API_URL"].to_s
    abort "Missing .env creds (DAYTONA_API_KEY / DAYTONA_API_URL)." if api_key.empty?

    # No dockerfile here → the client's DEFAULT_DOCKERFILE (bun+shell) builds the snapshot. A host
    # that needs more tooling passes config[:dockerfile] with its own image.
    box = Rbrun::Sandbox.new(
      provider: :daytona,
      config: { api_key: api_key, api_url: api_url },
      labels: { dogfood: "daytona" }
    )

    begin
      dog.header "box up"
      dog.ok "resolved a started box (find_or_create)", !box.id.to_s.empty?

      dog.header "files"
      box.write(File.join(box.workspace, "hello.txt"), "bonjour")
      dog.ok "wrote + read back a file", box.read(File.join(box.workspace, "hello.txt")) == "bonjour"
      dog.ok "exist? true for the written path", box.exist?(File.join(box.workspace, "hello.txt"))

      dog.header "exec"
      dog.ok "exec echo → ExecResult ok", box.exec("echo streamed").stdout == "streamed\n"

      dog.header "process session"
      box.session_create("s")
      cmd = box.session_exec("s", "printf 'AAAAABBBBB'")
      seen = String.new
      box.session_logs_follow("s", cmd, skip: 0, timeout: 30) { |c| seen << c; false }
      dog.ok "session streamed the command output", seen.include?("AAAAABBBBB")
    ensure
      box.destroy!
      dog.info "teardown", "box destroyed"
    end
  end
end
