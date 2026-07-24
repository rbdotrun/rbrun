require "test_helper"

module Rbrun
  class SkillFormTest < ActiveSupport::TestCase
    test "assemble → parse is a round-trip across every field" do
      form = Rbrun::SkillForm.new(
        name: "Changelog", label: "Changelog writer", tagline: "Ship notes, fast",
        icon: "scroll", kind: "artifact", example: "summarize what shipped this week",
        description: "Turn merged PRs into a human changelog.",
        body: "# Changelog\n\nDo the thing.\n",
        preferred_skills: %w[release-notes], preferred_tools: %w[save_artifact validate_step]
      )

      parsed = Rbrun::SkillForm.parse(form.skill_md)

      assert_equal "Changelog", parsed.name
      assert_equal "Changelog writer", parsed.label
      assert_equal "Ship notes, fast", parsed.tagline
      assert_equal "scroll", parsed.icon
      assert_equal "artifact", parsed.kind
      assert_equal "summarize what shipped this week", parsed.example
      assert_equal "Turn merged PRs into a human changelog.", parsed.description
      assert_equal %w[release-notes], parsed.preferred_skills
      assert_equal %w[save_artifact validate_step], parsed.preferred_tools
      assert_includes parsed.body, "# Changelog"
      assert_includes parsed.body, "Do the thing."
    end

    test "blank scalar keys and empty lists are omitted from the frontmatter" do
      md = Rbrun::SkillForm.new(name: "Bare", body: "just a body").skill_md
      assert_includes md, "name: Bare"
      refute_includes md, "label:"
      refute_includes md, "tagline:"
      refute_includes md, "preferred_skills:"
      refute_includes md, "preferred_tools:"
    end

    test "list fields reject blank entries (the multi_select hidden \"\" is dropped)" do
      form = Rbrun::SkillForm.new(name: "X", preferred_skills: [ "", "release-notes", "" ])
      assert_equal %w[release-notes], form.preferred_skills
    end

    test "from_version parses the archived SKILL.md; nil version is an empty form" do
      md    = Rbrun::SkillForm.new(name: "Packed", description: "d", body: "b").skill_md
      files = { "SKILL.md" => md, "reference.md" => "resource" }
      skill = Rbrun::Skill.create!(tenant: "acme", slug: "packed", name: "Packed")
      version = skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                               archive: Rbrun::SkillArchive.pack_files(files), source: :ui)

      form = Rbrun::SkillForm.from_version(version)
      assert_equal "Packed", form.name
      assert_equal "d", form.description
      assert_includes form.body, "b"

      assert_equal "", Rbrun::SkillForm.from_version(nil).name
    end
  end
end
