require "test_helper"
require "view_component/test_helpers"

class PrimitivesTest < ActiveSupport::TestCase
  include ViewComponent::TestHelpers

  def html(component, &block) = render_inline(component, &block).to_html

  test "spinner renders a status span with a size + variant" do
    out = html(Rbrun::Ui::Spinner::Component.new(size: :sm, variant: :primary))
    assert_includes out, "role=\"status\""
    assert_includes out, "w-4 h-4"
    assert_includes out, "text-default-600"
  end

  test "button renders variant + size and yields content" do
    out = html(Rbrun::Ui::Button::Component.new(variant: :primary, size: :xs, type: "submit")) { "Save" }
    assert_includes out, "<button"
    assert_includes out, "type=\"submit\""
    assert_includes out, "Save"
    assert_includes out, "bg-default-600"
  end

  test "badge renders its label and color" do
    out = html(Rbrun::Ui::Badge::Component.new(label: "New", color: :red))
    assert_includes out, "New"
    assert_includes out, "bg-red-50"
  end

  test "card renders title + block content, css override wins on the surface root" do
    # Card is a thin Surface wrapper (preset :card → rounded-lg on the root). A css: override
    # tailwind-merges onto the root, so it beats the preset's own radius.
    out = html(Rbrun::Ui::Card::Component.new(title: "T", css: "rounded-none")) { "body" }
    assert_includes out, "T"
    assert_includes out, "body"
    assert_includes out, "rounded-none"
    refute_includes out, "rounded-lg"
  end

  test "code_block renders escaped code with the language" do
    out = html(Rbrun::Ui::CodeBlock::Component.new(code: "puts 1 < 2", language: "ruby"))
    assert_includes out, "language-ruby"
    assert_includes out, "1 &lt; 2"
  end

  test "tooltip wraps content with the tip text" do
    out = html(Rbrun::Ui::Tooltip::Component.new(text: "help")) { "?" }
    assert_includes out, "?"
    assert_includes out, "help"
  end
end
