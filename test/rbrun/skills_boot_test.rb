require "test_helper"

class SkillsBootTest < ActiveSupport::TestCase
  test "seed_at_boot! no-ops when nothing is configured" do
    Rbrun.reset_config!
    assert_no_difference("Rbrun::Skill.count") { Rbrun::SkillSeeder.seed_at_boot! }
  end

  test "seed_at_boot! creates configured skills for the default tenant" do
    Rbrun.reset_config!
    Rbrun.config.skill "boot-skill", "# boot\n"
    assert_difference("Rbrun::Skill.count", 1) { Rbrun::SkillSeeder.seed_at_boot! }
    skill = Rbrun::Skill.for_tenant(Rbrun::Config::DEFAULT_TENANT).find_by(slug: "boot-skill")
    assert skill&.current_version, "the boot-seeded skill has a current version"
  end

  test "seed_at_boot! RAISES on a genuine skill error (unparseable source)" do
    Rbrun.reset_config!
    Rbrun.config.skill slug: "broken", name: "Broken", files: { "notes.txt" => "no SKILL.md here" }
    assert_raises(Rbrun::ConfigError) { Rbrun::SkillSeeder.seed_at_boot! }
  end

  test "seed_at_boot! warns but never applies a divergence" do
    Rbrun.reset_config!
    Rbrun.config.skill "diverge-skill", "# a\n"
    Rbrun::SkillSeeder.seed_at_boot!
    original = Rbrun::Skill.for_tenant(Rbrun::Config::DEFAULT_TENANT).find_by(slug: "diverge-skill").current_version.digest

    Rbrun.config.skills.clear
    Rbrun.config.skill "diverge-skill", "# b (changed)\n"
    Rbrun::SkillSeeder.seed_at_boot!

    skill = Rbrun::Skill.for_tenant(Rbrun::Config::DEFAULT_TENANT).find_by(slug: "diverge-skill")
    assert_equal original, skill.current_version.digest, "current unchanged"
    assert skill.diverged?, "divergence flagged"
  end
end
