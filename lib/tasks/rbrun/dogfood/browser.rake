# frozen_string_literal: true

require_relative "support"

# Phase 8 dogfood — the whole UI, for real, in a headless browser. Boots the mounted dummy app,
# signs in, opens a Worktree session, and drives ONE real conversation (real Claude + real Daytona +
# real GitHub) end to end: the user turn Turbo-appends, the working indicator shows, the agent commits
# a file (the commit pane renders), then hits an approval-gated tool so the footer appears — a click
# resumes the parked turn to completion. Screenshots land in tmp/dogfood. Creds/repo from .env
# (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY, GITHUB_PAT, RBRUN_WORKTREE_REPO).
#
# Runs in development: cable + ActiveJob are both :async (in-process), so Turbo broadcasts from the
# job thread reach the same process's WebSocket. No stubs, no ENV toggles.
#
#   bin/rails app:dogfood:browser

namespace :dogfood do
  desc "Phase 8: a real conversation drives the mounted UI in a headless browser (Turbo, working, approval, commits)"
  task browser: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    repo = ENV["RBRUN_WORKTREE_REPO"].to_s
    if [ ENV["ANTHROPIC_OAUTH_TOKEN"], ENV["DAYTONA_API_KEY"], ENV["GITHUB_PAT"] ].any? { |v| v.to_s.empty? } || repo.empty?
      abort "Missing .env (ANTHROPIC_OAUTH_TOKEN, DAYTONA_API_KEY, GITHUB_PAT, RBRUN_WORKTREE_REPO)."
    end

    require "capybara"
    require "capybara/cuprite"

    # Declared after :environment (ApplicationTool is autoloaded). An irreversible tool the agent must
    # route through the approval gate — this is what makes the footer appear in the browser.
    deploy = Class.new(Rbrun::ApplicationTool) do
      description "Deploy the app to production. Irreversible — always ask first."
      needs_approval!
      parameter :target, type: "string", description: "environment", required: false
      def execute(target: "production") = { "data" => "deployed to #{target}" }
      def name = "dogfood_deploy"
    end
    Rbrun.register_tool(deploy)

    # Override the dummy's local/dummy providers with the real backends; c.user (dev@rbrun.test) from
    # the dummy initializer is preserved — configure accumulates, it does not reset.
    Rbrun.configure do |c|
      c.github_pat       = ENV["GITHUB_PAT"]
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 24 } }
    end

    shots  = Rails.root.join("tmp/dogfood").tap { |d| FileUtils.mkdir_p(d) }
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    Capybara.app                   = Rails.application
    Capybara.server                = :puma, { Silent: true }
    Capybara.default_max_wait_time = 45
    Capybara.save_path             = shots.to_s
    Capybara.register_driver(:rbrun) do |app|
      Capybara::Cuprite::Driver.new(app,
        headless: true, window_size: [ 1400, 1000 ],
        browser_path: (File.exist?(chrome) ? chrome : nil),
        process_timeout: 40, timeout: 45, js_errors: false)
    end
    page = Capybara::Session.new(:rbrun)
    shot = ->(name) { page.save_screenshot(shots.join("browser_#{name}.png").to_s); dog.info "screenshot", "tmp/dogfood/browser_#{name}.png" }

    wt = Rbrun::Worktree.create!(tenant: "rbrun", repo:, base: "main")
    begin
      dog.header "provisioning the worktree"
      wt.provision!
      dog.ok "the branch was spun + checked out", wt.head_sha.present?
      session = wt.sessions.create!

      dog.header "sign in (auth is mandatory)"
      page.visit "/rbrun/login"
      page.fill_in "email", with: "dev@rbrun.test"
      page.fill_in "password", with: "password"
      page.click_button "Sign in"
      dog.ok "signed in and reached the app", page.has_no_current_path?("/rbrun/login", wait: 15)

      dog.header "open the conversation + send a message"
      page.visit "/rbrun/c/#{session.id}"
      dog.ok "the composer is on the page", page.has_selector?("#composer textarea", wait: 15)
      prompt = "First create a file NOTE_#{Time.now.to_i}.md with a one-line note and commit+push it " \
               "with git (git add, git commit -m 'rbrun dogfood note', git push). THEN deploy to " \
               "production using the dogfood_deploy tool."
      page.find("#composer textarea[name='message[content]']").set(prompt)
      page.find("#composer button[aria-label='Send']").click

      dog.header "Turbo appends the turn + the working indicator shows"
      dog.ok "the user turn Turbo-appended into the timeline",
             page.has_selector?("#conversation_#{session.id}", text: "dogfood_deploy tool", wait: 20)
      dog.ok "the working indicator appeared", page.has_text?("The agent is working", wait: 20)
      shot.("working")

      dog.header "the commit pane renders the pushed commit"
      dog.ok "a commit rendered in the commit pane",
             page.has_selector?("#commits_#{session.id}", text: "rbrun dogfood note", wait: 120)
      shot.("commits")

      dog.header "the approval footer appears + a decision resumes the turn"
      dog.ok "the approval footer appeared (run parked)", page.has_button?("Approve", wait: 120)
      dog.ok "the run parked server-side (needs_approval)", session.reload.needs_approval?
      shot.("approval")

      page.click_button "Approve"
      dog.ok "the working indicator returned (turn resumed)", page.has_text?("The agent is working", wait: 20)
      dog.ok "the approval footer cleared", page.has_no_button?("Approve", wait: 60)
      dog.ok "the turn finished (done, footer gone, composer live)",
             page.has_selector?("#composer button[aria-label='Send']", wait: 120)
      dog.ok "status landed on done", session.reload.done?
      shot.("done")

      dog.header "what landed"
      dog.ok "rbrun recorded at least one commit", session.commits.any?
      dog.info "commit", session.commits.last&.slice(:sha, :message)&.values&.join(" — ")
      dog.info "reply", session.messages.where(event_type: "text", role: "assistant").last&.content.to_s.squish[0, 160]
    ensure
      Capybara.reset_sessions!
      page.driver.quit
      wt.sandbox.destroy! if wt.persisted?
      wt.destroy! if wt.persisted?
    end
  end
end
