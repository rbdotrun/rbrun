# frozen_string_literal: true

require "test_helper"

module Rbrun
  class SkillSeederRailsKamalTest < ActiveSupport::TestCase
    test "rails-kamal-deployment is an authored built-in skill" do
      dir = Rbrun::Engine.root.join("app/skills/rails-kamal-deployment")
      assert dir.join("SKILL.md").exist?, "SKILL.md missing"
      assert_includes Rbrun::SkillSeeder.builtin_authored.map { |s| s[:slug] }, "rails-kamal-deployment"
    end
  end
end
