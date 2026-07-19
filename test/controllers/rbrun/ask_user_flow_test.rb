require "test_helper"

module Rbrun
  class AskUserFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    FORM = { "title" => "Pick a color", "steps" => [ { "questions" => [
      { "key" => "color", "label" => "Which color?", "input" => "radio",
        "options" => [ { "value" => "red", "label" => "Red" }, { "value" => "blue", "label" => "Blue" } ],
        "required" => true } ] } ] }.freeze

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session = @worktree.sessions.create!
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
      @session.messages.create!(role: "user", event_type: "text", content: "help me pick")
      @gate = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "au1",
        approval_status: "pending", payload: { "name" => "ask_user", "input" => { "form_spec" => FORM } })
    end

    test "the ask_user card renders its stepper options (resolved by convention, not Default)" do
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "form[action=?]", "/rbrun/ask_user/au1"
      assert_select "input[type=radio][value=red]"
      assert_select "input[type=radio][value=blue]"
    end

    test "submitting picks records them as the tool_result, resumes, and marks answered" do
      assert_enqueued_with(job: Rbrun::AskUserTurnJob) do
        post "/rbrun/ask_user/au1", params: { answers: { color: "red" } }
      end
      assert_response :success
      assert @gate.reload.approval_answered?

      result = @session.messages.find_by(event_type: "tool_result", tool_use_id: "au1")
      assert_equal({ "color" => [ "red" ] }, result.payload.dig("result", "answers"))
    end

    test "a double submit is a no-op (the claim is the lock)" do
      post "/rbrun/ask_user/au1", params: { answers: { color: "red" } }
      assert_no_difference("Rbrun::SessionMessage.where(event_type: 'tool_result').count") do
        post "/rbrun/ask_user/au1", params: { answers: { color: "blue" } }
      end
    end
  end
end
