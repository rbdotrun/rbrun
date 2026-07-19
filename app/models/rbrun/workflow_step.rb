module Rbrun
  # One ordered step of a Workflow definition. Carries no per-run state — progress lives in
  # WorkflowStepCompletion, keyed by session.
  class WorkflowStep < ApplicationRecord
    belongs_to :workflow, class_name: "Rbrun::Workflow"
    has_many :completions, class_name: "Rbrun::WorkflowStepCompletion", dependent: :destroy

    validates :title, presence: true
  end
end
