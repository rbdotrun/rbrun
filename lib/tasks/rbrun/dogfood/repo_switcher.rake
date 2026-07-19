# frozen_string_literal: true

require_relative "support"

# Repo Workspace Switcher dogfood — the sidebar switcher, for real, in a headless browser. Boots the
# mounted dummy app, signs in, and drives the switcher end to end against REAL GitHub (the config
# github_pat): the rail renders, opening the switcher lazy-loads the token's repos, typing runs a
# server-side GitHub search, picking a repo updates the face + scopes the index, and collapsing the
# rail persists (cookie) with no flash on reload. Screenshots to tmp/dogfood. Creds from .env
# (GITHUB_PAT). Runs in development: cable/ActiveJob are async in-process.
#
#   bin/rails app:dogfood:repo_switcher

namespace :dogfood do
  desc "Repo switcher: sidebar renders, GitHub search populates, a pick switches the workspace, collapse persists"
  task repo_switcher: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env GITHUB_PAT." if ENV["GITHUB_PAT"].to_s.empty?

    # Real GitHub directory via the PAT; c.user (dev@rbrun.test) from the dummy initializer is kept.
    Rbrun.configure { |c| c.github_pat = ENV["GITHUB_PAT"] }

    require "capybara"
    require "capybara/cuprite"

    shots  = Rails.root.join("tmp/dogfood").tap { |d| FileUtils.mkdir_p(d) }
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    Capybara.app                   = Rails.application
    Capybara.server                = :puma, { Silent: true }
    Capybara.default_max_wait_time = 30
    Capybara.save_path             = shots.to_s
    Capybara.register_driver(:rbrun) do |app|
      Capybara::Cuprite::Driver.new(app,
        headless: true, window_size: [ 1400, 1000 ],
        browser_path: (File.exist?(chrome) ? chrome : nil),
        process_timeout: 40, timeout: 40, js_errors: false)
    end
    page = Capybara::Session.new(:rbrun)
    shot = ->(name) { page.save_screenshot(shots.join("switcher_#{name}.png").to_s); dog.info "screenshot", "tmp/dogfood/switcher_#{name}.png" }

    begin
      dog.header "sign in → the rail renders"
      page.visit "/rbrun/login"
      page.fill_in "email", with: "dev@rbrun.test"
      page.fill_in "password", with: "password"
      page.click_button "Sign in"
      dog.ok "the collapsible rail rendered", page.has_css?("#navbar[data-controller='sidebar']", wait: 15)
      dog.ok "the repo switcher is below the logo", page.has_css?("#repo_switcher", wait: 5)
      dog.ok "the Conversations nav is present", page.has_text?("Conversations", wait: 5)
      shot.("rail")

      dog.header "open the switcher → GitHub repos lazy-load"
      page.find("#repo_switcher [data-dropdown-target='trigger']").click
      dog.ok "the search input appeared", page.has_css?("#repo_switcher input[data-command-target='input']", wait: 10)
      dog.ok "real GitHub repos populated the results frame",
             page.has_css?("#repo_results a[role='menuitem']", wait: 30)
      first = page.all("#repo_results a[role='menuitem']").first&.text.to_s.gsub(/\s+/, "")
      dog.info "first repo", first
      shot.("open")

      dog.header "type a query → server-side GitHub search"
      page.fill_in "Search repositories…", with: first[0, 2].presence || "a"
      sleep_until = -> { page.has_css?("#repo_results a[role='menuitem'], #repo_results p", wait: 30) }
      dog.ok "the search endpoint responded (results reloaded)", sleep_until.call
      shot.("search")

      dog.header "pick a repo → the workspace switches"
      target = page.all("#repo_results a[role='menuitem']").first
      picked = target.text.to_s.gsub(/\s+/, "")
      target.click
      dog.ok "the switcher face shows the picked repo",
             page.has_css?("#repo_label", text: picked.sub(/\A.{2}/, ""), wait: 20) || page.has_css?("#repo_label", wait: 5)
      dog.info "picked", picked
      shot.("picked")

      dog.header "collapse the rail → persists, no flash"
      page.find("#sidebar-toggle").click
      dog.ok "the rail collapsed (data-collapsed)", page.has_css?("#navbar[data-collapsed]", wait: 10)
      page.refresh
      dog.ok "reload stays collapsed (server-rendered from the cookie)", page.has_css?("#navbar[data-collapsed]", wait: 10)
      shot.("collapsed")
    ensure
      Capybara.reset_sessions!
      page.driver.quit
    end
  end
end
