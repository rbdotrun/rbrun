require "application_system_test_case"

module Rbrun
  # The scenario (skill-bound workflow) authoring form, driven in a real headless browser. The emphasis
  # is nested-field error handling: a WorkflowStep with a description but no title must surface a field
  # error and preserve what the user typed — the form must NOT silently drop it.
  class ScenarioFormTest < ApplicationSystemTestCase
    setup do
      visit "/rbrun/login"
      fill_in "email", with: "dev@rbrun.test"
      fill_in "password", with: "password"
      click_button "Sign in"
      @skill = Rbrun::Skill.create!(tenant: "rbrun", slug: "changelog", name: "Changelog")
    end

    test "authoring a scenario: add a step, submit valid, it persists" do
      visit "/rbrun/skills/changelog/workflows/new"
      fill_in "workflow[label]", with: "Weekly notes"
      fill_in "workflow[prompt]", with: "summarize the week"

      first("input[name^='workflow[steps_attributes]'][name$='[title]']").set("Collect PRs")
      first("textarea[name^='workflow[steps_attributes]'][name$='[description]']").set("gather merged PRs")

      click_button "+ Add step"
      titles = all("input[name^='workflow[steps_attributes]'][name$='[title]']")
      assert_equal 2, titles.size
      titles.last.set("Group by type")

      click_button "Create scenario"

      assert_current_path "/rbrun/skills/changelog/edit"
      wf = @skill.workflows.find_by(label: "Weekly notes")
      assert wf
      assert_equal [ "Collect PRs", "Group by type" ], wf.steps.order(:position).pluck(:title)
    end

    test "a nested step with a description but no title surfaces a field error and preserves input" do
      visit "/rbrun/skills/changelog/workflows/new"
      fill_in "workflow[label]", with: "Bad step"
      # leave the step title blank but give it a description → not all-blank → invalid
      first("textarea[name^='workflow[steps_attributes]'][name$='[description]']").set("content but no title")

      click_button "Create scenario"

      # the server re-renders unprocessable_entity with the nested error + the entered value preserved
      assert_text "can't be blank"
      assert_equal "content but no title",
                   first("textarea[name^='workflow[steps_attributes]'][name$='[description]']").value
      assert_equal 0, @skill.workflows.count
    end

    test "removing a new row drops it before submit" do
      visit "/rbrun/skills/changelog/workflows/new"
      fill_in "workflow[label]", with: "One step only"
      first("input[name$='[title]']").set("Keep me")

      click_button "+ Add step"
      assert_equal 2, all("input[name$='[title]']").size

      all("button", text: "Remove").last.click
      assert_equal 1, all("input[name$='[title]']").size

      click_button "Create scenario"
      assert_equal 1, @skill.workflows.find_by(label: "One step only").steps.count
    end
  end
end
