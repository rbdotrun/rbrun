class NullifyCompletionUserMessage < ActiveRecord::Migration[8.1]
  # `user_message` is provenance (which turn recorded the completion), not a lifeline: destroying the
  # session must not be blocked by the order its messages vs. completions are reaped. Nullify on delete.
  def change
    remove_foreign_key :rbrun_workflow_step_completions, :rbrun_session_messages, column: :user_message_id
    add_foreign_key :rbrun_workflow_step_completions, :rbrun_session_messages,
                    column: :user_message_id, on_delete: :nullify
  end
end
