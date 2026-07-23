class AddDescriptionToRbrunWorkflowSteps < ActiveRecord::Migration[8.1]
  # A step can carry what it means / what to validate — used by scenario dogfoods (the step's
  # description = what the agent must prove) and available to authored workflows.
  def change
    add_column :rbrun_workflow_steps, :description, :text
  end
end
