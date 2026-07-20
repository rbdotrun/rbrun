require "test_helper"

module Rbrun
  class RepoSecretTest < ActiveSupport::TestCase
    test "value is encrypted at rest but readable through the model" do
      s = Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "RAILS_MASTER_KEY", value: "supersecret")
      assert_equal "supersecret", s.reload.value
      raw = Rbrun::RepoSecret.connection.select_value("SELECT value FROM rbrun_repo_secrets WHERE id = #{s.id}")
      refute_includes raw.to_s, "supersecret", "the value is ciphertext at rest"
    end

    test "unique per [tenant, repo, key]" do
      Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "K", value: "1")
      assert_raises(ActiveRecord::RecordNotUnique) do
        Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "K", value: "2")
      end
    end

    test "for_repo + for_tenant scope" do
      mine = Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "a/b", key: "K", value: "1")
      Rbrun::RepoSecret.create!(tenant: "rbrun", repo: "c/d", key: "K", value: "2")
      assert_equal [ mine ], Rbrun::RepoSecret.for_tenant("rbrun").for_repo("a/b").to_a
    end
  end
end
