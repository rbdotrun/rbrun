require "test_helper"
require "view_component/test_helpers"

class MenuDropdownTest < ActiveSupport::TestCase
  include ViewComponent::TestHelpers

  def html(component, &block) = render_inline(component, &block).to_html

  test "menu renders current heading, links, and a separator in order" do
    out = html(Rbrun::Ui::Menu::Component.new) do |m|
      m.current "rbdotrun/rbrun", avatar: "RB"
      m.link "rbdotrun/scratch", href: "/switch", avatar: "RB"
      m.separator
      m.link "Add a repo", href: "/new", icon: "plus"
    end

    assert_includes out, "role=\"menu\""
    assert_includes out, "data-controller=\"menu\""
    assert_includes out, "rbdotrun/rbrun"          # current heading
    assert_includes out, "role=\"menuitem\""       # links
    assert_includes out, "data-menu-target=\"item\""
    assert_includes out, "role=\"separator\""
    assert_includes out, "/switch"
  end

  test "menu link marked active gets aria-current and a trailing check" do
    out = html(Rbrun::Ui::Menu::Component.new) do |m|
      m.link "rbdotrun/rbrun", href: "/x", avatar: "RB", active: true
    end
    assert_includes out, "aria-current=\"true\""
    assert_includes out, "bg-slate-100 font-medium"   # ACTIVE classes
  end

  test "dropdown wires the controller contract and nests trigger + menu" do
    out = html(Rbrun::Ui::Dropdown::Component.new(placement: :top_start, trigger_class: "block w-full")) do |d|
      d.with_trigger { "<button type=\"button\">Repo ▾</button>".html_safe }
      d.with_menu { |m| m.link "Sign out", href: "/logout", icon: "log-out" }
    end

    assert_includes out, "data-controller=\"dropdown\""
    assert_includes out, "data-dropdown-placement-value=\"top-start\""
    assert_includes out, "data-dropdown-target=\"trigger\""
    assert_includes out, "data-action=\"click-&gt;dropdown#toggle\""
    assert_includes out, "data-dropdown-target=\"content\""
    assert_includes out, "Repo ▾"
    assert_includes out, "Sign out"
    assert_includes out, "role=\"menu\""
  end

  test "nav_item marked active gets aria-current=page + active classes + icon" do
    out = html(Rbrun::Ui::NavItem::Component.new(label: "Conversations", href: "/c", icon: "messages-square", active: true))
    assert_includes out, "aria-current=\"page\""
    assert_includes out, "bg-default-50 text-default-700"
    assert_includes out, "Conversations"
    assert_includes out, "<svg"   # lucide icon
  end

  test "nav_item inactive by default renders inactive classes" do
    out = html(Rbrun::Ui::NavItem::Component.new(label: "Docs", href: "/docs", icon: "file"))
    assert_includes out, "text-slate-600"
    refute_includes out, "aria-current"
  end

  test "nav_group renders label + the collapsed 1px line stand-in" do
    out = html(Rbrun::Ui::NavGroup::Component.new(label: "Library"))
    assert_includes out, "Library"
    assert_includes out, "group-data-[collapsed]/sidebar:opacity-100"   # the LINE
    assert_includes out, "aria-hidden=\"true\""
  end
end
