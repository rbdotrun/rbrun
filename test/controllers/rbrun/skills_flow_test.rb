require "test_helper"

module Rbrun
  class SkillsFlowTest < ActionDispatch::IntegrationTest
    FILES  = { "SKILL.md" => "# stored\n" }.freeze
    FILES2 = { "SKILL.md" => "# authored (changed)\n" }.freeze

    def dig(files) = Rbrun::SkillArchive.digest_files(files)

    setup do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      @skill = Rbrun::Skill.create!(tenant: "rbrun", slug: "pdf", name: "PDF report")
      @skill.promote!(digest: dig(FILES), archive: Rbrun::SkillArchive.pack_files(FILES), source: :inline)
    end

    # author_divergence! mutates the shared config.skills array in place; the config snapshot restores
    # the reference, not the contents, so reset it back to the dummy's empty state here.
    teardown { Rbrun.config.skills.clear }

    def author_divergence!(files)
      Rbrun.config.skills.clear
      Rbrun.config.skill "pdf", files["SKILL.md"]
    end

    test "index lists the tenant's skills" do
      get "/rbrun/skills"
      assert_response :success
      assert_select "h1", text: "Skills"
      assert_includes @response.body, "PDF report"
      assert_includes @response.body, "pdf"
    end

    test "a diverged authored source surfaces a banner + the diff" do
      author_divergence!(FILES2)
      get "/rbrun/skills"
      assert_includes @response.body, "differs from the stored version"
      assert_includes @response.body, "# authored (changed)"   # authored pane
      assert_includes @response.body, "# stored"               # current pane
    end

    test "Reload adopts the authored source as a new current version" do
      author_divergence!(FILES2)
      assert_difference("Rbrun::SkillVersion.count", 1) do
        post "/rbrun/skills/pdf/reconcile", params: { decision: "reload" }
      end
      assert_redirected_to "/rbrun/skills"
      assert_equal dig(FILES2), @skill.reload.current_version.digest
      assert_nil @skill.divergence_digest
    end

    test "Keep stored records the reviewed digest and leaves current" do
      author_divergence!(FILES2)
      assert_no_difference("Rbrun::SkillVersion.count") do
        post "/rbrun/skills/pdf/reconcile", params: { decision: "keep" }
      end
      assert_equal dig(FILES),  @skill.reload.current_version.digest, "current unchanged"
      assert_equal dig(FILES2), @skill.dismissed_digest

      # And a re-render no longer flags it as diverged.
      get "/rbrun/skills"
      assert_select ".border-amber-300", count: 0
    end

    test "the index's New skill button links to the authoring form" do
      get "/rbrun/skills"
      assert_response :success
      assert_select "a[href=?]", "/rbrun/skills/new", text: /New skill/
    end

    test "GET new renders an empty skill form" do
      get "/rbrun/skills/new"
      assert_response :success
      assert_select "form[action=?][method=post]", "/rbrun/skills"
      assert_select "input[name=?]", "skill[name]"
      assert_select "textarea[name=?]", "skill[body]"
    end

    test "POST skills creates a skill with a v1 assembled from the form" do
      assert_difference("Rbrun::Skill.count", 1) do
        post "/rbrun/skills", params: { skill: {
          name: "Changelog", label: "Changelog writer", description: "PRs → notes",
          body: "# Changelog\n\nDo it.", preferred_skills: [ "", "create-skill" ], preferred_tools: [ "" ]
        } }
      end
      skill = Rbrun::Skill.for_tenant("rbrun").find_by!(slug: "changelog")
      assert_equal "Changelog", skill.name
      assert skill.current_version.present?
      assert_equal "ui", skill.current_version.source
      md = Rbrun::SkillArchive.files(skill.current_version.archive)["SKILL.md"]
      assert_includes md, "name: Changelog"
      assert_includes md, "# Changelog"
      assert_redirected_to "/rbrun/skills/changelog/edit"
    end

    test "GET edit loads the current version's fields" do
      create_ui_skill("editme", name: "Edit Me", body: "original body")
      get "/rbrun/skills/editme/edit"
      assert_response :success
      assert_select "input[name=?][value=?]", "skill[name]", "Edit Me"
      assert_select "textarea[name=?]", "skill[body]", text: /original body/
    end

    test "PATCH skills promotes a new version, preserving the base version's other files" do
      skill = create_ui_skill("editme", name: "Edit Me", body: "v1 body",
                              extra: { "reference.md" => "keep me" })
      assert_difference("skill.versions.count", 1) do
        patch "/rbrun/skills/editme", params: { skill: { name: "Edit Me", body: "v2 body" } }
      end
      skill.reload
      files = Rbrun::SkillArchive.files(skill.current_version.archive)
      assert_includes files["SKILL.md"], "v2 body"
      assert_equal "keep me", files["reference.md"], "non-SKILL.md files survive an edit"
      assert_redirected_to "/rbrun/skills/editme/edit"
    end

    test "GET edit?version= loads that specific version into the form" do
      skill = create_ui_skill("editme", name: "Edit Me", body: "v1 body")
      v1 = skill.current_version
      patch "/rbrun/skills/editme", params: { skill: { name: "Edit Me", body: "v2 body" } }

      get "/rbrun/skills/editme/edit", params: { version: v1.id }
      assert_response :success
      assert_select "textarea[name=?]", "skill[body]", text: /v1 body/
    end

    test "POST skills with a taken slug re-renders new with an error (no clobber)" do
      create_ui_skill("changelog", name: "Changelog", body: "b")
      assert_no_difference("Rbrun::Skill.count") do
        post "/rbrun/skills", params: { skill: { name: "Changelog", body: "dupe" } }
      end
      assert_response :unprocessable_entity
    end

    private

      # A skill whose current version is a UI-authored SKILL.md (+ optional extra files).
      def create_ui_skill(slug, name:, body:, extra: {})
        skill = Rbrun::Skill.create!(tenant: "rbrun", slug:, name:)
        md    = Rbrun::SkillForm.new(name:, body:).skill_md
        files = { "SKILL.md" => md }.merge(extra)
        skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                       archive: Rbrun::SkillArchive.pack_files(files), source: :ui)
        skill
      end
  end
end
