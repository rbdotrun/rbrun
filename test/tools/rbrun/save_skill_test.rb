require "test_helper"

module Rbrun
  class SaveSkillTest < ActiveSupport::TestCase
    # Serves a workspace folder (glob + read) instead of touching a real box.
    class FakeSandbox
      def initialize(tree) = @tree = tree # { "folder/rel" => bytes }
      def workspace = "/ws"

      def glob(dir)
        prefix = "#{dir}/"
        @tree.keys.filter_map { |path| path.delete_prefix(prefix) if path.start_with?(prefix) }.sort
      end

      def read(path) = @tree.fetch(path)
    end

    def with_folder(tree)
      @sandbox = FakeSandbox.new(tree)
      @session.worktree.instance_variable_set(:@sandbox, @sandbox)
    end

    setup do
      @session = rbrun_session(tenant: "acme")
    end

    test "the tool name demodulizes to save_skill" do
      assert_equal "save_skill", Rbrun::Tools::SaveSkill.new(tenant: "acme").name
    end

    test "the tool is gated" do
      assert Rbrun::Tools::SaveSkill.needs_approval?
    end

    test "executing packs the folder and promotes it as the tenant's current version" do
      with_folder(
        "greet/SKILL.md" => "---\nname: Greeter\ndescription: greets\n---\nsay hi\n",
        "greet/refs/notes.md" => "notes"
      )

      result = Rbrun::Tools::SaveSkill.in_session(@session).execute(folder_path: "greet")

      assert_equal "greet", result.dig("data", "slug")
      assert_equal "Greeter", result.dig("data", "name")
      assert_equal true, result.dig("data", "created")
      assert_equal %w[SKILL.md refs/notes.md], result.dig("data", "files")

      skill = Rbrun::Skill.for_tenant("acme").find_by!(slug: "greet")
      assert_equal "ui", skill.current_version.source
      files = Rbrun::SkillArchive.files(skill.current_version.archive)
      assert_equal "say hi\n", files["SKILL.md"].sub(/\A---.*?---\n/m, "")
    end

    test "the name falls back to a titleized slug when frontmatter has no name" do
      with_folder("my-cool-skill/SKILL.md" => "no frontmatter here")
      result = Rbrun::Tools::SaveSkill.in_session(@session).execute(folder_path: "my-cool-skill")
      assert_equal "My Cool Skill", result.dig("data", "name")
    end

    test "re-saving a changed folder promotes a new current version" do
      with_folder("greet/SKILL.md" => "---\nname: Greeter\n---\nv1\n")
      Rbrun::Tools::SaveSkill.in_session(@session).execute(folder_path: "greet")
      first = Rbrun::Skill.for_tenant("acme").find_by!(slug: "greet").current_version

      with_folder("greet/SKILL.md" => "---\nname: Greeter\n---\nv2 changed\n")
      result = Rbrun::Tools::SaveSkill.in_session(@session).execute(folder_path: "greet")

      assert_equal false, result.dig("data", "created")
      second = Rbrun::Skill.for_tenant("acme").find_by!(slug: "greet").current_version
      refute_equal first.id, second.id
    end

    test "a folder without SKILL.md is a recoverable error" do
      with_folder("greet/readme.txt" => "nope")
      result = Rbrun::Tools::SaveSkill.in_session(@session).execute(folder_path: "greet")
      assert_match(/SKILL\.md/, result["error"])
    end
  end
end
