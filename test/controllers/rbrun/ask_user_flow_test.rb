require "test_helper"

module Rbrun
  class AskUserFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    # value ≠ label on purpose — the case that exposes a missing trust boundary / raw-value nudge.
    FORM = { "title" => "Narrow it down", "steps" => [ { "questions" => [
      { "key" => "region", "label" => "Which region?", "input" => "radio",
        "options" => [ { "value" => "idf", "label" => "Île-de-France" }, { "value" => "paca", "label" => "PACA" } ],
        "required" => true } ] } ] }.freeze

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session = @worktree.sessions.create!
      @session.messages.create!(role: "user", event_type: "text", content: "help me pick")
      @gate = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "au1",
        approval_status: "pending", payload: { "name" => "ask_user", "input" => { "form_spec" => FORM } })
    end

    def result_row = @session.messages.find_by(event_type: "tool_result", tool_use_id: "au1")

    test "the card renders its stepper options (resolved by convention, not Default)" do
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "form[action=?]", "/rbrun/ask_user/au1"
      assert_select "input[type=radio][value=idf]"
      assert_select "input[type=radio][value=paca]"
    end

    test "a valid pick records the answer, resumes with a LABEL-resolved nudge, marks answered" do
      assert_enqueued_with(job: Rbrun::AskUserTurnJob,
                           args: [ @session.id, "The user answered the form:\n- Which region? → Île-de-France\nContinue with these choices." ]) do
        post "/rbrun/ask_user/au1", params: { answers: { region: "idf" } }
      end
      assert_response :success
      assert @gate.reload.approval_answered?
      assert_equal({ "region" => [ "idf" ] }, result_row.payload.dig("result", "answers"))
    end

    test "a value NOT in the declared options is rejected (422) — the trust boundary" do
      assert_no_enqueued_jobs do
        post "/rbrun/ask_user/au1", params: { answers: { region: "mars" } }
      end
      assert_response :unprocessable_entity
      assert_nil result_row, "nothing recorded"
      refute @gate.reload.approval_answered?, "gate not claimed"
    end

    test "an unknown field is rejected (422)" do
      post "/rbrun/ask_user/au1", params: { answers: { region: "idf", evil: "x" } }
      assert_response :unprocessable_entity
      assert_nil result_row
    end

    test "a skipped required question is rejected (422)" do
      post "/rbrun/ask_user/au1", params: { answers: {} }
      assert_response :unprocessable_entity
      assert_nil result_row
    end

    test "a double submit is a no-op (the claim is the lock)" do
      post "/rbrun/ask_user/au1", params: { answers: { region: "idf" } }
      assert_no_difference("Rbrun::SessionMessage.where(event_type: 'tool_result').count") do
        post "/rbrun/ask_user/au1", params: { answers: { region: "paca" } }
      end
    end
  end
end
