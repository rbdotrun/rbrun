require "test_helper"

module Rbrun
  class WorkflowSkillSeedTest < ActiveSupport::TestCase
    test "the workflow-creator built-in is among the authored sources" do
      slugs = Rbrun::SkillSeeder.authored_from_config(Rbrun.config).map { |s| s[:slug] }
      assert_includes slugs, "workflow-creator"
    end

    test "seeding creates the workflow-creator skill with a current version" do
      Rbrun::SkillSeeder.from_config(Rbrun.config, tenant: "rbrun").call
      skill = Rbrun::Skill.for_tenant("rbrun").find_by(slug: "workflow-creator")
      assert skill, "skill seeded"
      assert skill.current_version, "has a current version to stage"
    end
  end
end
