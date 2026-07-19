module Rbrun
  module Sessions
    module Commits
      # The Worktree commit pane — the git history the agent pushed, beside the conversation. rbrun's
      # replacement for insiti's artifacts region. Its own broadcast target (commits_<id>).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(session:)
          @session = session
        end

        attr_reader :session
      end
    end
  end
end
