require "test_helper"

module Rbrun
  class Composer::RepoBadgeTest < ViewComponent::TestCase
    def badge_html(session:)
      with_controller_class(Rbrun::ApplicationController) do
        render_inline(Rbrun::Composer::RepoBadge::Component.new(session:)).to_html
      end
    end

    test "no session (root) → editable: picker trigger + hidden fields, ✕ hidden" do
      html = badge_html(session: nil)
      assert_match %(data-controller="repo-badge"), html
      assert_match %(name="repo"), html
      assert_match %(name="base"), html
      assert_match %(data-turbo-frame="modal"), html
      assert_match(/data-action="repo-badge#clear"[^>]*class="[^"]*\bhidden\b/, html)
    end

    test "a session with no turns is still editable and prefills its repo" do
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/web")
      s  = wt.sessions.create!
      html = badge_html(session: s)
      assert_match %(data-controller="repo-badge"), html
      assert_match %(data-turbo-frame="modal"), html
      assert_match "acme/web", html
    end

    test "a session with a turn → locked chip, no picker, no ✕" do
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/web")
      s  = wt.sessions.create!
      s.messages.create!(role: "user", event_type: "text", content: "go")
      html = badge_html(session: s)
      refute_match %(data-controller="repo-badge"), html
      refute_match %(data-turbo-frame="modal"), html
      assert_match "acme/web", html
    end
  end
end
