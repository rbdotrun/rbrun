require "test_helper"

module Rbrun
  class SkillScenariosTest < ActiveSupport::TestCase
    setup do
      @skill = Rbrun::Skill.create!(tenant: "acme", slug: "release-notes", name: "Release Notes")
    end

    def with_scenarios(*yamls)
      require "tmpdir"
      dir = Dir.mktmpdir("skill-")
      FileUtils.mkdir_p(File.join(dir, "scenarios"))
      yamls.each_with_index { |y, i| File.write(File.join(dir, "scenarios", "s#{i}.yml"), y) }
      yield dir
    ensure
      FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
    end

    SCENARIO = <<~YAML
      label: Writes release notes
      description: the release-notes skill drafts notes and saves them as an artifact
      prompt: Write release notes for our v1.2 release and save them.
      steps:
        - label: Draft the notes
          description: writes a NOTES.md with a version title
        - label: Save the artifact
          description: calls save_artifact and a version exists
    YAML

    test "ingest upserts one skill-bound workflow keyed [skill, label], idempotent" do
      with_scenarios(SCENARIO) do |dir|
        assert_equal 1, Rbrun::SkillScenarios.ingest(@skill, dir)
        assert_equal 1, Rbrun::SkillScenarios.ingest(@skill, dir) # idempotent (find-or-init)

        wf = @skill.workflows.for_tenant("acme").find_by!(label: "Writes release notes")
        assert_equal "Write release notes for our v1.2 release and save them.", wf.prompt
        assert_equal 2, wf.steps.count
        assert_equal "Draft the notes", wf.steps.first.title
        assert_equal 1, @skill.workflows.count
      end
    end

    test "a blank-label scenario is skipped" do
      with_scenarios("description: no label\nprompt: hi\n") do |dir|
        assert_equal 0, Rbrun::SkillScenarios.ingest(@skill, dir)
      end
    end

    test "reap_unauthored! drops scenarios + skills no longer authored, keeps authored ones" do
      # @skill is release-notes (an authored builtin): one authored scenario + one that's no longer on disk.
      kept  = @skill.workflows.create!(tenant: "acme", label: "Writes and saves release notes", prompt: "x")
      stale = @skill.workflows.create!(tenant: "acme", label: "Ghost scenario", prompt: "y")
      # a whole skill with no authored source
      ghost = Rbrun::Skill.create!(tenant: "acme", slug: "no-such-skill", name: "Ghost")
      ghost.workflows.create!(tenant: "acme", label: "whatever", prompt: "z")

      reaped = Rbrun::SkillScenarios.reap_unauthored!("acme", Rbrun.config)

      assert Rbrun::Workflow.exists?(kept.id),  "authored scenario kept"
      refute Rbrun::Workflow.exists?(stale.id), "stale scenario reaped"
      assert Rbrun::Skill.exists?(@skill.id),   "authored skill kept"
      refute Rbrun::Skill.exists?(ghost.id),    "unauthored skill reaped"
      assert_equal 3, reaped # stale scenario + ghost skill + ghost's workflow
    end

    test "scenarios/ is excluded from the staged archive (read_dir)" do
      require "tmpdir"
      dir = Dir.mktmpdir("skill-")
      File.write(File.join(dir, "SKILL.md"), "# hi")
      FileUtils.mkdir_p(File.join(dir, "scenarios"))
      File.write(File.join(dir, "scenarios", "x.yml"), "label: X")

      files = Rbrun::SkillArchive.read_dir(dir)
      assert_includes files.keys, "SKILL.md"
      refute(files.keys.any? { |k| k.start_with?("scenarios/") }, "scenarios must not be staged")
    ensure
      FileUtils.remove_entry(dir) if dir && Dir.exist?(dir)
    end
  end
end
