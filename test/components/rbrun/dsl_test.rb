require "test_helper"
require "view_component/test_helpers"

class DslTest < ActiveSupport::TestCase
  include ViewComponent::TestHelpers

  # A component authored in the DSL: option/param + style variants + inline erb_template + cn() merge.
  class Widget < Rbrun::ApplicationViewComponent
    option :tone, default: proc { :default }
    option :css, optional: true

    style do
      base { "rounded p-2" }
      variants do
        tone do
          default { "bg-gray-100" }
          danger  { "bg-red-100" }
        end
      end
    end

    erb_template <<~ERB
      <div class="<%= cn(style(tone:), css) %>" data-controller="<%= controller_name %>"><%= content %></div>
    ERB
  end

  test "option + style variants render" do
    html = render_inline(Widget.new(tone: :danger)) { "hi" }.to_html
    assert_includes html, "bg-red-100"
    assert_includes html, "rounded"
    assert_includes html, "hi"
  end

  test "css override wins via tailwind_merge (later utility beats base)" do
    html = render_inline(Widget.new(css: "p-8")).to_html
    assert_includes html, "p-8"
    refute_includes html, "p-2"
  end

  test "controller_name derives the stimulus id from the class name" do
    html = render_inline(Widget.new).to_html
    assert_match(/data-controller="[a-z-]+--widget"/, html)
  end
end
