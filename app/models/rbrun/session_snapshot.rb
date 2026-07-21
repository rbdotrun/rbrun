module Rbrun
  # The engine-owned durable copy of ONE session's SDK resume history: the box's <workspace>/.claude,
  # tarred (minus the re-staged skills). One row per session, upserted each turn by Rbrun::ClaudeSnapshot.
  # It is what makes a turn idempotent — a lost box is rebuilt and the conversation resumes (invariant #11).
  # The pure sandbox gem knows nothing of this; the engine drives it via the sandbox's exec/read/write.
  class SessionSnapshot < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :session, class_name: "Rbrun::Session"
    before_validation :inherit_tenant, on: :create

    validates :data, presence: true

    private

    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= session&.tenant
  end
end
