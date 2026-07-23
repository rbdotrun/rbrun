require "test_helper"

module Rbrun
  class SkeletonTest < ViewComponent::TestCase
    test "list_item variant draws the requested number of shimmer rows, aria-hidden" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::Skeleton::Component.new(variant: :list_item, rows: 3)).to_html
      end
      assert_match %(aria-hidden="true"), html
      assert_match "animate-pulse", html
      # 3 rows × 3 bars (avatar + two lines) = 9 pulsing bars.
      assert_equal 9, html.scan("animate-pulse").length
    end

    test "defaults to six list_item rows" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::Skeleton::Component.new).to_html
      end
      assert_equal 18, html.scan("animate-pulse").length
    end
  end
end
