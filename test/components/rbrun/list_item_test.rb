require "test_helper"

module Rbrun
  class ListItemTest < ViewComponent::TestCase
    test "renders a menuitem link with avatar, title, and subtitle" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::ListItem::Component.new(
          title: "rbdotrun/rbrun", subtitle: "rbdotrun", avatar: "RB", href: "/x"
        )).to_html
      end
      assert_match %(role="menuitem"), html
      assert_match %(data-menu-target="item"), html
      assert_match "rbdotrun/rbrun", html
      assert_match ">rbdotrun<", html   # the subtitle line
      assert_match "RB", html           # the avatar
    end

    test "active marks aria-current and renders a check" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::ListItem::Component.new(title: "a/b", href: "/x", active: true)).to_html
      end
      assert_match %(aria-current="true"), html
      assert_match "M20 6 9 17l-5-5", html   # the lucide check icon path
    end

    test "without href renders a non-interactive div" do
      html = with_controller_class(Rbrun::ApplicationController) do
        render_inline(Ui::ListItem::Component.new(title: "a/b")).to_html
      end
      assert_match %(<div), html
      assert_match %(role="menuitem"), html
    end
  end
end
