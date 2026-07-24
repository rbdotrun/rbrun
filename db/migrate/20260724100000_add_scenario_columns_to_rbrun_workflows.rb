class AddScenarioColumnsToRbrunWorkflows < ActiveRecord::Migration[8.1]
  # A skill-bound workflow IS that skill's scenario/example: skill_id (present ⇒ scenario), an example
  # prompt to replay, and a pointer to the artifact its last run produced (the showcase). All nullable —
  # a plain conversation workflow leaves them nil.
  def change
    add_reference :rbrun_workflows, :skill, null: true, foreign_key: { to_table: :rbrun_skills }
    add_column    :rbrun_workflows, :prompt, :text
    add_reference :rbrun_workflows, :showcase_artifact_version, null: true,
                  foreign_key: { to_table: :rbrun_artifact_versions }
  end
end
