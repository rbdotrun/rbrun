# frozen_string_literal: true

require "test_helper"

module Rbrun
  class SkillSeederPreviewDeployTest < ActiveSupport::TestCase
    test "preview-deploy is an authored built-in skill with SKILL.md + example templates" do
      dir = Rbrun::Engine.root.join("app/skills/preview-deploy")
      assert dir.join("SKILL.md").exist?, "SKILL.md missing"
      assert dir.join("examples/deploy.yml").exist?, "examples/deploy.yml missing"
      assert dir.join("examples/Dockerfile.rails").exist?, "examples/Dockerfile.rails missing"

      assert_includes Rbrun::SkillSeeder.builtin_authored.map { |s| s[:slug] }, "preview-deploy"
    end
  end
end
