require "test_helper"

module Rbrun
  class ReloadSkillsTest < ActiveSupport::TestCase
    # Records writes instead of touching a real box.
    class FakeSandbox
      attr_reader :writes

      def initialize = @writes = {}
      def workspace = "/ws"
      def write(path, content) = @writes[path] = content
    end

    setup do
      @session = rbrun_session(tenant: "acme")
      @sandbox = FakeSandbox.new
      @session.worktree.instance_variable_set(:@sandbox, @sandbox)
    end

    test "the tool name demodulizes to reload_skills" do
      assert_equal "reload_skills", Rbrun::Tools::ReloadSkills.new(tenant: "acme").name
    end

    test "executing re-stages the tenant's current skill versions from the DB into the workspace" do
      files = { "SKILL.md" => "# staged\n", "t.txt" => "x" }
      skill = Rbrun::Skill.create!(tenant: "acme", slug: "pdf", name: "PDF")
      skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                     archive: Rbrun::SkillArchive.pack_files(files), source: :inline)

      result = Rbrun::Tools::ReloadSkills.in_session(@session).execute

      assert_equal 1, result.dig("data", "reloaded")
      assert_equal "effective next turn", result.dig("data", "note")
      assert_equal "# staged\n", @sandbox.writes["/ws/.claude/skills/pdf/SKILL.md"]
      assert_equal "x", @sandbox.writes["/ws/.claude/skills/pdf/t.txt"]
    end

    test "another tenant's skills are not staged" do
      other = Rbrun::Skill.create!(tenant: "other", slug: "secret", name: "S")
      other.promote!(digest: "d", archive: Rbrun::SkillArchive.pack_files({ "SKILL.md" => "no" }), source: :inline)

      result = Rbrun::Tools::ReloadSkills.in_session(@session).execute
      assert_equal 0, result.dig("data", "reloaded")
      assert_empty @sandbox.writes
    end
  end
end
