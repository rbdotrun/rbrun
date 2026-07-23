require "test_helper"

module Rbrun
  class ReportsFlowTest < ActionDispatch::IntegrationTest
    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      @lead = @session.messages.create!(role: "user", event_type: "text", content: "do it")
      @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "t1", payload: { "name" => "x" })
      @session.messages.create!(role: "assistant", event_type: "text", content: "done")
    end

    test "a completed turn shows the report footer (metadata + Report an error)" do
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "#turn_footer_#{@lead.id}"
      assert_select "a[href=?]", "/rbrun/c/#{@session.id}/report/#{@lead.id}", text: /Report an error/
      assert_select "#turn_footer_#{@lead.id}", text: /tool call/
    end

    test "the report link opens the dialog in the modal frame" do
      get "/rbrun/c/#{@session.id}/report/#{@lead.id}"
      assert_response :success
      assert_select "turbo-frame#modal"
      assert_select "form[action=?]", "/rbrun/c/#{@session.id}/report/#{@lead.id}"
    end

    test "filing a report creates it and flips the footer to Reported" do
      assert_difference("Rbrun::TurnReport.count", 1) do
        post "/rbrun/c/#{@session.id}/report/#{@lead.id}", params: { comment: "wrong answer" }, as: :turbo_stream
      end
      report = Rbrun::TurnReport.order(:id).last
      assert_equal "wrong answer", report.comment
      assert_equal @lead, report.user_message
      assert_equal [ @session.messages.where(role: "assistant").pluck(:id) ].flatten.sort,
                   report.turn_messages.pluck(:id).sort
      assert_response :success
      assert_match "turn_footer_#{@lead.id}", response.body
      assert_match "Reported", response.body
    end

    test "reporting is idempotent — one report per turn" do
      post "/rbrun/c/#{@session.id}/report/#{@lead.id}", params: { comment: "a" }
      assert_no_difference("Rbrun::TurnReport.count") do
        post "/rbrun/c/#{@session.id}/report/#{@lead.id}", params: { comment: "b" }
      end
    end
  end
end
