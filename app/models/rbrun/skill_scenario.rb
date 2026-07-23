module Rbrun
  # The seed of a self-validating dogfood: a vague `prompt` to replay and the ordered `steps` it should
  # produce — each `{label, description}`, where `description` is *what to validate*. Hand-authored in a
  # skill's `scenarios/*.yml`, ingested here (never staged into the agent's workspace). A run seeds a
  # workflow from the steps, replays the prompt in an autonomous session, and reads back what the agent
  # self-validated. No validation DSL — validation is 100% the agent's (see Rbrun::SkillScenarioRun).
  class SkillScenario < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :skill, class_name: "Rbrun::Skill"

    validates :label, presence: true
    validates :prompt, presence: true

    # Steps as an ordered list of { "label" =>, "description" => }; attachments as repo-relative paths.
    def step_list = Array(steps)
    def attachment_list = Array(attachments)
  end
end
