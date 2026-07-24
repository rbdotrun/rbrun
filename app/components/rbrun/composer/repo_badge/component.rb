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

        def editable? = @session.nil? || @session.messages.none?
        def repo = @session&.worktree&.repo.presence
        def base = @session&.worktree&.base.presence
      end
    end
  end
end
