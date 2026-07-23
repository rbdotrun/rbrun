module Rbrun
  module Sessions
    module TurnFooter
      # The per-turn footer (ported from insitix's rating footer): on the left, how long the turn took
      # and how many tools it called; on the right, "Report an error" (in place of insitix's star
      # rating) — or a "Reported" confirmation once filed. `turn_footer_<lead.id>` is the replace target
      # so filing a report flips it in place. Takes only the turn's lead user message — the agent rows
      # come from `user_message.turn_replies`.
      class Component < Rbrun::ApplicationViewComponent
        def initialize(user_message:)
          @user_message = user_message
        end

        attr_reader :user_message

        def dom_id = "turn_footer_#{user_message.id}"

        def replies = @replies ||= user_message.turn_replies.to_a

        def tool_count = replies.count(&:tool_use?)
        def tool_label = "#{tool_count} tool call#{'s' unless tool_count == 1}"

        # Wall time from the user's message to the last row of the turn, humanised (e.g. "8s", "1m 4s").
        def duration_label
          last = (replies.map(&:created_at) + [ user_message.created_at ]).max
          secs = (last - user_message.created_at).to_i
          secs < 60 ? "#{secs}s" : "#{secs / 60}m #{secs % 60}s"
        end

        def report = @report ||= Rbrun::TurnReport.for_tenant(user_message.session.tenant)
                                                  .find_by(user_message_id: user_message.id)
        def reported? = report.present?
      end
    end
  end
end
