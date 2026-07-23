require "test_helper"

module Rbrun
  class ArtifactTest < ActiveSupport::TestCase
    setup do
      @session = rbrun_session(tenant: "acme")
      @message = @session.messages.create!(role: "user", event_type: "text", content: "make a report")
    end

    test "append_version! creates a new artifact, version 1, attaches the blob, sets current_version" do
      version = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("hello"), filename: "notes.txt"
      )

      artifact = version.artifact
      assert_equal "acme", artifact.tenant
      assert_equal "notes.txt", artifact.name
      assert_equal 1, version.number
      assert_equal artifact.current_version, version
      assert version.file.attached?
      assert_equal "text/plain", version.content_type
      assert_equal 5, version.byte_size
      assert_equal @message, version.message
    end

    test "append_version! with artifact_id appends version 2 and advances current_version" do
      v1 = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("a"), filename: "notes.txt"
      )
      v2 = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("bb"), filename: "notes.txt",
        artifact_id: v1.artifact_id
      )

      assert_equal v1.artifact_id, v2.artifact_id
      assert_equal 2, v2.number
      assert_equal v2, v1.artifact.reload.current_version
      assert_equal 2, v1.artifact.versions.count
    end

    test "append_version! with an explicit name uses it over the basename" do
      version = Rbrun::Artifact.append_version!(
        tenant: "acme", message: @message, io: StringIO.new("x"), filename: "notes.txt", name: "Quarterly report"
      )
      assert_equal "Quarterly report", version.artifact.name
    end

    test "append_version! rejects another tenant's artifact_id" do
      other = Rbrun::Artifact.append_version!(
        tenant: "other", message: @message, io: StringIO.new("x"), filename: "notes.txt"
      )
      assert_raises(ActiveRecord::RecordNotFound) do
        Rbrun::Artifact.append_version!(
          tenant: "acme", message: @message, io: StringIO.new("y"), filename: "notes.txt",
          artifact_id: other.artifact_id
        )
      end
    end
  end
end
