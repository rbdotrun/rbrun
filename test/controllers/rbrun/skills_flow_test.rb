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

    test "the index shows a New skill button that targets the drawer" do
      get "/rbrun/skills"
      assert_response :success
      assert_select "form[action=?][data-turbo-frame=drawer]", "/rbrun/skills/new"
    end

    test "New skill opens a create-skill conversation in the drawer" do
      assert_difference("Rbrun::Session.count", 1) do
        post "/rbrun/skills/new"
      end
      session = Rbrun::Session.order(:id).last
      assert_equal %w[create-skill], session.preferred_skills
      assert_equal Rbrun::SkillsController::SKILLS_REPO, session.worktree.repo
      assert_response :success
      assert_select "turbo-frame#drawer"
    end

    test "New skill reuses one skills worktree per tenant" do
      assert_difference("Rbrun::Worktree.count", 1) do
        post "/rbrun/skills/new"
        post "/rbrun/skills/new"
      end
    end
  end
end
