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

    test "in a chat (session present) → locked chip, no picker, no ✕ — even before the first turn lands" do
      wt = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/web")
      s  = wt.sessions.create! # no turns yet — still a chat, so locked
      html = badge_html(session: s)
      refute_match %(data-controller="repo-badge"), html
      refute_match %(data-turbo-frame="modal"), html
      assert_match "acme/web", html
    end
  end
end
