require "test_helper"

module Rbrun
  class SecretsFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    # value ≠ key on purpose — proves the value never leaks anywhere.
    DECL = { "secrets" => [
      { "key" => "RAILS_MASTER_KEY", "label" => "Rails master key", "required" => true },
      { "key" => "SENTRY_DSN", "label" => "Sentry DSN" }
    ] }.freeze
    VALUE = "0f1e2d3c-super-secret".freeze

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      post "/rbrun/repos/switch", params: { repo: "a/b", base: "main" }
      @session.messages.create!(role: "user", event_type: "text", content: "run the app")
      @gate = @session.messages.create!(role: "assistant", event_type: "tool_use", tool_use_id: "sec1",
        approval_status: "pending", payload: { "name" => "request_secrets", "input" => DECL })
    end

    def result_row = @session.messages.find_by(event_type: "tool_result", tool_use_id: "sec1")

    test "the card renders secure password inputs (resolved by convention)" do
      get "/rbrun/c/#{@session.id}"
      assert_response :success
      assert_select "form[action=?]", "/rbrun/secrets/sec1"
      assert_select "input[type=password][name=?]", "secrets[RAILS_MASTER_KEY]"
      assert_select "input[type=password][name=?]", "secrets[SENTRY_DSN]"
    end

    test "a valid submit encrypts the value, records + resumes with KEYS ONLY (no value anywhere)" do
      assert_enqueued_with(job: Rbrun::SecretsTurnJob) do
        post "/rbrun/secrets/sec1", params: { secrets: { RAILS_MASTER_KEY: VALUE } }
      end
      assert_response :success

      secret = Rbrun::RepoSecret.for_tenant("rbrun").for_repo("a/b").find_by(key: "RAILS_MASTER_KEY")
      assert_equal VALUE, secret.value, "stored + decryptable"

      # The value must never appear in the tool_result payload or its content.
      assert_equal [ "RAILS_MASTER_KEY" ], result_row.payload.dig("result", "stored_keys")
      refute_includes result_row.payload.to_json, VALUE, "no value in the tool_result payload"
      refute_includes result_row.content.to_s, VALUE, "no value in the tool_result content"

      # And never in the resume nudge.
      job = enqueued_jobs.find { |j| j["job_class"] == "Rbrun::SecretsTurnJob" }
      refute_includes job["arguments"].to_json, VALUE, "no value in the resume nudge"

      assert @gate.reload.approval_answered?
    end

    test "a missing required secret is rejected (422), nothing claimed or stored" do
      assert_no_enqueued_jobs do
        post "/rbrun/secrets/sec1", params: { secrets: { SENTRY_DSN: "x" } }
      end
      assert_response :unprocessable_entity
      assert_nil result_row
      assert @gate.reload.approval_pending?
      assert_nil Rbrun::RepoSecret.find_by(key: "RAILS_MASTER_KEY")
    end

    test "an unknown field is rejected (422)" do
      post "/rbrun/secrets/sec1", params: { secrets: { RAILS_MASTER_KEY: VALUE, EVIL: "x" } }
      assert_response :unprocessable_entity
      assert_nil result_row
    end

    test "a double submit is a no-op (the claim is the lock)" do
      post "/rbrun/secrets/sec1", params: { secrets: { RAILS_MASTER_KEY: VALUE } }
      assert_no_difference("Rbrun::SessionMessage.where(event_type: 'tool_result').count") do
        post "/rbrun/secrets/sec1", params: { secrets: { RAILS_MASTER_KEY: "other" } }
      end
    end
  end
end
