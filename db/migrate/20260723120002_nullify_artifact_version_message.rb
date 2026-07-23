class NullifyArtifactVersionMessage < ActiveRecord::Migration[8.1]
  # An artifact has no ownership and outlives its context (spec). So a version's `message` is
  # provenance, not a lifeline: when the producing session/message is deleted the version SURVIVES and
  # simply loses the pointer — never blocked, never cascaded.
  def change
    change_column_null :rbrun_artifact_versions, :message_id, true
    remove_foreign_key :rbrun_artifact_versions, :rbrun_session_messages, column: :message_id
    add_foreign_key :rbrun_artifact_versions, :rbrun_session_messages, column: :message_id, on_delete: :nullify
  end
end
