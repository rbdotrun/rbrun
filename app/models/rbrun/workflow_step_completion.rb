module Rbrun
  # A step marked done in ONE session's run, in a specific turn (user_message = the turn lead). Progress
  # is per-session: the same step is completed independently in each run. Unique per [session, step].
  class WorkflowStepCompletion < ApplicationRecord
    belongs_to :session, class_name: "Rbrun::Session"
    belongs_to :workflow_step, class_name: "Rbrun::WorkflowStep"
    belongs_to :user_message, class_name: "Rbrun::SessionMessage", optional: true
  end
end
