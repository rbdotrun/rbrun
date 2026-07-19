module Rbrun
  # A commit the agent pushed during a turn — rbrun records the SHA (GitHub is the store).
  class Commit < ApplicationRecord
    belongs_to :worktree, class_name: "Rbrun::Worktree"
    belongs_to :session,  class_name: "Rbrun::Session", optional: true
  end
end
