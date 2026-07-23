require "test_helper"

module Rbrun
  class SurfaceTest < ViewComponent::TestCase
    def render_surface(**kwargs, &blk)
      with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::Surface::Component.new(**kwargs), &blk)
      end
    end

    test "root is a heightless flex column with the preset chrome" do
      html = render_surface(preset: :dialog).to_html
      assert_match "flex-auto", html
      assert_match "min-h-0", html
      assert_match "flex-col", html
      assert_match "rounded-xl", html      # :dialog chrome
      refute_match "h-full", html          # never imposes its own height
    end

    test "header renders title, back, description, close and actions; body scrolls" do
      html = render_surface(title: "T", back: "/x", description: "D", close: true) do |s|
        s.with_actions { "ACT" }
        s.with_body { "BODY" }
      end.to_html
      assert_match "<h2", html
      assert_match "T", html
      assert_match "D", html
      assert_match %(aria-label="Back"), html               # back link
      assert_match %(data-action="overlay#close"), html     # close button
      assert_match "ACT", html
      assert_match "overflow-y-auto", html                  # body is the single scroll region
      assert_match "BODY", html
    end

    test "no header content -> no header bar" do
      html = render_surface { |s| s.with_body { "B" } }.to_html
      refute_match "<h2", html
      refute_match "<header", html
    end

    test "footer + fixed areas + region ids render" do
      html = render_surface(body_id: "drawer_body", footer_id: "drawer_actions") do |s|
        s.with_fixed_area { "TABS" }
        s.with_body { "B" }
        s.with_footer { "FOOT" }
      end.to_html
      assert_match "TABS", html
      assert_match %(id="drawer_body"), html
      assert_match %(id="drawer_actions"), html
      assert_match "FOOT", html
    end

    test "insets: centered wraps a max-w column; padded pads the body" do
      centered = render_surface(inset: :centered) { |s| s.with_body { "B" } }.to_html
      assert_match "max-w-3xl", centered
      padded = render_surface(inset: :padded) { |s| s.with_body { "B" } }.to_html
      assert_match "p-6", padded
    end

    test "elevation adds a shadow" do
      assert_match "shadow-xl", render_surface(elevation: :lg) { |s| s.with_body { "B" } }.to_html
    end
  end
end
