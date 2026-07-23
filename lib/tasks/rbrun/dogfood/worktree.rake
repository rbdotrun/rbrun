# frozen_string_literal: true

require_relative "support"

# Phase 6 dogfood — a real Worktree turn (real Daytona box + real GitHub). Creates a Worktree (branch
# off base), provisions the sandbox, runs a turn where the agent writes a file and commits+pushes via
# git, and confirms the commit landed on the branch and was recorded. Creds/repo from .env
# (GITHUB_PAT, RBRUN_WORKTREE_REPO, DAYTONA_*, ANTHROPIC_OAUTH_TOKEN).
#
#   bin/rails app:dogfood:worktree

namespace :dogfood do
  desc "Phase 6: a real turn in a Worktree edits a file and pushes a commit to GitHub"
  task worktree: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    repo = ENV["RBRUN_WORKTREE_REPO"].to_s
    if ENV["GITHUB_PAT"].to_s.empty? || repo.empty? || ENV["DAYTONA_API_KEY"].to_s.empty? || ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty?
      abort "Missing .env (GITHUB_PAT, RBRUN_WORKTREE_REPO, DAYTONA_API_KEY, ANTHROPIC_OAUTH_TOKEN)."
    end

    Rbrun.configure do |c|
      c.github_pat       = ENV["GITHUB_PAT"]
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 20 } }
    end

    wt = Rbrun::Worktree.create!(tenant: "dogfood", repo:, base: "main")
    begin
      dog.header "provisioning"
      wt.provision!
      dog.ok "the branch was spun + checked out", wt.head_sha.present?
      base_sha = wt.head_sha

      session = wt.sessions.create!
      session.run_turn(
        "Create a file NOTES_#{Time.now.to_i}.md with a one-line note, then commit it with git " \
        "(git add, git commit -m 'rbrun dogfood note') and push it to the current branch."
      )

      dog.header "the turn"
      dog.ok "status landed on done", session.reload.done?

      dog.header "the commit"
      dog.ok "HEAD advanced past the base", wt.head_sha.present? && wt.head_sha != base_sha
      dog.ok "rbrun recorded at least one commit", session.commits.any?
      dog.info "commit", session.commits.last&.slice(:sha, :message)&.values&.join(" — ")
      remote = wt.sandbox.exec("cd #{wt.sandbox.workspace} && git ls-remote origin #{wt.branch}").stdout.to_s
      dog.ok "the branch exists on GitHub (git ls-remote)", remote.include?(wt.branch)
    ensure
      wt.sandbox.destroy!
      wt.destroy!
    end
  end
end
