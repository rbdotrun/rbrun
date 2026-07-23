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

    test "header renders title, back, subtitle, close and actions; body scrolls" do
      html = render_surface(title: "T", back: "/x", subtitle: "D", close: true) do |s|
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

    test "insets: centered wraps a max-w column; padded pads the body with the shared x + a vertical" do
      centered = render_surface(inset: :centered) { |s| s.with_body { "B" } }.to_html
      assert_match "max-w-3xl", centered
      padded = render_surface(inset: :padded) { |s| s.with_body { "B" } }.to_html
      assert_match "px-6", padded   # the shared x (size :lg) — not a bespoke p-6
      assert_match "py-4", padded
    end

    test "one normalized x-inset is shared by header, fixed strip, body and footer; it scales with size" do
      md = render_surface(title: "T", size: :md, inset: :padded) do |s|
        s.with_fixed_area { "TABS" }
        s.with_body { "B" }
        s.with_footer { "F" }
      end.to_html
      assert_equal 4, md.scan("px-4").length     # header + fixed_area + body + footer, all px-4
      refute_match "px-6", md
      refute_match "px-3", md

      lg = render_surface(title: "T", size: :lg, inset: :padded) { |s| s.with_body { "B" } }.to_html
      assert_match "px-6", lg                     # same knob, larger at :lg
    end

    test "elevation adds a shadow" do
      assert_match "shadow-xl", render_surface(elevation: :lg) { |s| s.with_body { "B" } }.to_html
    end

    test "heading level: defaults to h2, honors :h1" do
      assert_match "<h2", render_surface(title: "T").to_html
      assert_match "<h1", render_surface(title: "T", heading: :h1).to_html
    end

    test "size preset scales the header (declared height, no vertical padding) + title type" do
      lg = render_surface(title: "T", size: :lg).to_html
      assert_match "h-16", lg
      assert_match "text-xl", lg
      md = render_surface(title: "T", size: :md).to_html
      assert_match "h-14", md
      assert_match "text-lg", md
    end
  end
end
