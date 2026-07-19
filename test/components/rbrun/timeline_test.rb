require "test_helper"
require "view_component/test_helpers"

module Rbrun
  class TimelineTest < ActiveSupport::TestCase
    include ViewComponent::TestHelpers

    setup do
      @session = rbrun_session
      @session.messages.create!(role: "user", event_type: "text", content: "hi")
      @session.messages.create!(role: "assistant", event_type: "text", content: "**bold** reply")
      @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t1",
                                payload: { "name" => "search", "input" => { "q" => "cats" } })
      @session.messages.create!(role: "tool", event_type: "tool_result", tool_use_id: "t1",
                                payload: { "tool_use_id" => "t1", "result" => { "hits" => 3 }, "is_error" => false })
    end

    def timeline_html
      render_inline(Rbrun::Conversation::Timeline::Component.new(messages: @session.messages.to_a, working: false)).to_html
    end

    test "renders assistant prose as markdown" do
      assert_includes timeline_html, "<strong>bold</strong>"
    end

    test "groups tool calls into an actions accordion showing the tool name" do
      html = timeline_html
      assert_includes html, "1 action"
      assert_includes html, "search"
      assert_includes html, "q: cats"
    end

    test "renders the tool result body" do
      assert_includes timeline_html, "hits"
    end

    test "dom_id_for keys a tools run by its first call and a prose block by its row id" do
      assert_equal "work_9", Rbrun::Conversation::Segment::Component.dom_id_for(:tools, [ Struct.new(:id).new(9) ])
      assert_equal "seg_7", Rbrun::Conversation::Segment::Component.dom_id_for(:prose, Struct.new(:id).new(7))
    end
  end
end
