require "test_helper"

module Rbrun
  class SkillScenariosTest < ActiveSupport::TestCase
    setup do
      @skill = Rbrun::Skill.create!(tenant: "acme", slug: "create-skill", name: "Create Skill")
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
      label: Builds a dad-joke skill
      description: create-skill authors and promotes a small skill
      prompt: Make me a skill that tells a dad joke.
      steps:
        - label: Author the folder
          description: writes SKILL.md with frontmatter
        - label: Promote it
          description: calls save_skill and the skill is promoted
    YAML

    test "ingest upserts a scenario row keyed [skill, label], idempotent" do
      with_scenarios(SCENARIO) do |dir|
        assert_equal 1, Rbrun::SkillScenarios.ingest(@skill, dir)
        assert_equal 1, Rbrun::SkillScenarios.ingest(@skill, dir) # idempotent (find-or-init)

        scenario = Rbrun::SkillScenario.for_tenant("acme").find_by!(skill: @skill, label: "Builds a dad-joke skill")
        assert_equal "Make me a skill that tells a dad joke.", scenario.prompt
        assert_equal 2, scenario.step_list.size
        assert_equal "Author the folder", scenario.step_list.first["label"]
        assert_equal 1, Rbrun::SkillScenario.for_tenant("acme").where(skill: @skill).count
      end
    end

    test "a blank-label scenario is skipped" do
      with_scenarios("description: no label\nprompt: hi\n") do |dir|
        assert_equal 0, Rbrun::SkillScenarios.ingest(@skill, dir)
      end
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
