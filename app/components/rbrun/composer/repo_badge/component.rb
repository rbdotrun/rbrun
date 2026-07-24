module Rbrun
  module Composer
    module RepoBadge
      # The composer's repo selector. Editable while a chat has no turns (opens the switcher dialog and
      # writes hidden repo/base into the compose form via the repo-badge Stimulus controller); locked
      # (a read-only chip) once the chat has started. No global scope — the repo is a per-form field.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(session: nil)
          @session = session
        end

        # Only the root composer (no session yet) picks a repo. In a chat the repo is fixed — the badge
        # is a read-only chip. (A just-created session whose first turn is still enqueuing is already a
        # chat, so `session.nil?` — not `messages.none?` — is the right test; it never flickers editable.)
        def editable? = @session.nil?
        def repo = @session&.worktree&.repo.presence
        def base = @session&.worktree&.base.presence
      end
    end
  end
end
