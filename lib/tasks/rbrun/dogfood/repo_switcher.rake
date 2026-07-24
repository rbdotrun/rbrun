# frozen_string_literal: true

require_relative "support"

# Repo selection dogfood — the COMPOSER badge, for real, in a headless browser. Boots the mounted dummy
# app, signs in, and drives repo selection end to end against REAL GitHub (the config github_pat): the
# root composer shows the repo badge (no sidebar switcher), opening it lazy-loads the token's repos,
# typing runs a server-side GitHub search, and picking a repo is a CLIENT-SIDE pick that fills the badge
# (no POST, no global scope). Stops before starting a chat (that would fire a real agent turn). Also
# checks the rail collapse/persist. Screenshots to tmp/dogfood. Creds from .env (GITHUB_PAT). Runs in
# development: cable/ActiveJob are async in-process.
#
#   bin/rails app:dogfood:repo_switcher

namespace :dogfood do
  desc "Composer repo badge: the dialog opens, GitHub search populates, a client-side pick fills the badge"
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
      dog.header "sign in → the root composer + repo badge render (no sidebar switcher)"
      page.visit "/rbrun/login"
      page.fill_in "email", with: "dev@rbrun.test"
      page.fill_in "password", with: "password"
      page.click_button "Sign in"
      dog.ok "the collapsible rail rendered", page.has_css?("#navbar[data-controller='sidebar']", wait: 15)
      dog.ok "the sidebar switcher is GONE", page.has_no_css?("#repo_switcher", wait: 5)
      dog.ok "the composer repo badge is present", page.has_css?("[data-controller='repo-badge']", wait: 10)
      shot.("root")

      dog.header "open the badge → the dialog opens, GitHub repos lazy-load"
      page.find("[data-controller='repo-badge'] a[data-turbo-frame='modal']").click
      dog.ok "the dialog opened", page.has_css?("dialog[open]", wait: 10)
      dog.ok "the search input appeared", page.has_css?("dialog[open] input[data-command-target='input']", wait: 10)
      dog.ok "real GitHub repos populated the results frame",
             page.has_css?("#repo_results [role='menuitem'][data-repo]", wait: 30)
      first = page.all("#repo_results [role='menuitem'][data-repo]").first["data-repo"]
      dog.info "first repo", first
      shot.("open")

      dog.header "type a query → server-side GitHub search"
      page.fill_in "Search repositories…", with: (first.split("/").last.to_s[0, 3].presence || "a")
      dog.ok "the search endpoint responded (results reloaded)",
             page.has_css?("#repo_results [role='menuitem'], #repo_results p", wait: 30)
      shot.("search")

      dog.header "pick a repo → CLIENT-SIDE: the dialog closes, the badge fills (no POST)"
      target = page.all("#repo_results [role='menuitem'][data-repo]").first
      picked = target["data-repo"]
      target.click
      dog.ok "the dialog closed", page.has_no_css?("dialog[open]", wait: 15)
      dog.ok "the badge shows the picked repo", page.has_css?("[data-controller='repo-badge']", text: picked, wait: 20)
      dog.ok "the clear ✕ appeared", page.has_css?("[data-repo-badge-target='clear']:not(.hidden)", wait: 10)
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
