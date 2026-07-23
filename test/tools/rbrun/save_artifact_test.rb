require "test_helper"

module Rbrun
  class SaveArtifactTest < ActiveSupport::TestCase
    # Serves file bytes instead of touching a real box.
    class FakeSandbox
      def initialize(files) = @files = files
      def workspace = "/ws"
      def read(path) = @files.fetch(path)
    end

    setup do
      @session = rbrun_session(tenant: "acme")
      @session.messages.create!(role: "user", event_type: "text", content: "make a report")
      @sandbox = FakeSandbox.new("report.md" => "# Title\nbody\n")
      @session.worktree.instance_variable_set(:@sandbox, @sandbox)
    end

    test "the tool name demodulizes to save_artifact" do
      assert_equal "save_artifact", Rbrun::Tools::SaveArtifact.new(tenant: "acme").name
    end

    test "the tool is ungated" do
      refute Rbrun::Tools::SaveArtifact.needs_approval?
    end

    test "executing reads the workspace file and creates a versioned artifact" do
      result = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md")

      data = result.fetch("data")
      assert_equal 1, data["version"]
      assert_equal "report.md", data["name"]
      assert_operator data["byte_size"], :>, 0

      artifact = Rbrun::Artifact.for_tenant("acme").find(data["artifact_id"])
      assert artifact.current_version.file.attached?
      assert_equal "# Title\nbody\n", artifact.current_version.file.download
    end

    test "passing artifact_id appends a second version" do
      first  = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md")
      id     = first.dig("data", "artifact_id")
      second = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md", artifact_id: id)

      assert_equal 2, second.dig("data", "version")
      assert_equal id, second.dig("data", "artifact_id")
    end

    test "an unknown artifact_id returns a recoverable error" do
      result = Rbrun::Tools::SaveArtifact.in_session(@session).execute(path: "report.md", artifact_id: 999_999)
      assert_match(/not found/, result["error"])
    end
  end
end
