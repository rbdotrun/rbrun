# frozen_string_literal: true

require "rbrun/sandbox"
require_relative "support"

# Phase 2 dogfood — the DAYTONA sandbox, for real (live cloud box). Same contract as sandbox_local,
# against a real Daytona sandbox. Credentials come from the dummy app's Rails credentials
# (daytona.api_key / daytona.api_url) — a secret store, not a variable: dogfood is never parameterized.
# Needs :environment to load credentials.
#
#   bin/rails app:dogfood:sandbox_daytona

namespace :dogfood do
  desc "Phase 2: the daytona sandbox runs the full contract for real (live cloud box)"
  task sandbox_daytona: :environment do
    dog = Rbrun::Dogfood
    creds = Rails.application.credentials.dig(:daytona) || {}
    if creds[:api_key].to_s.empty?
      abort "No daytona credentials. Set daytona.api_key / daytona.api_url via `bin/rails credentials:edit` in test/dummy."
    end

    # No dockerfile here → the client's DEFAULT_DOCKERFILE (bun+shell) builds the snapshot. A host
    # that needs more tooling passes config[:dockerfile] with its own image.
    box = Rbrun::Sandbox.new(
      provider: :daytona,
      config: { api_key: creds[:api_key], api_url: creds[:api_url] },
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
