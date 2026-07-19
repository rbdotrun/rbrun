module Rbrun
  module Sessions
    # The agent's side of one turn as a sequence of SEGMENTS: assistant text → :prose; the app's own
    # voice → :internal; a RUN of consecutive tool events → one :tools accordion. This object is both
    # the initial renderer AND the source of truth a live broadcast consults (segment_index_for /
    # segment_at / open_at? / anchor? / results) — so live == reload.
    module Timeline
      class Component < Rbrun::ApplicationViewComponent
        def initialize(messages:, working: false)
          @messages = messages
          @working = working
        end

        attr_reader :working

        def segments
          @segments ||= begin
            out = []
            run = []
            rows.each do |m|
              next if m.tool_result?

              if m.tool_use?
                run << m
              elsif m.event_type == "internal"
                flush(out, run)
                run = []
                out << [ :internal, m ]
              elsif m.content.present? && m.event_type != "token"
                flush(out, run)
                run = []
                out << [ :prose, m ]
              end
            end
            flush(out, run)
            out
          end
        end

        def results = @results ||= @messages.select(&:tool_result?).index_by(&:tool_use_id)

        def open_at?(index)
          kind, payload = segments[index]
          return false unless kind == :tools

          (working && index == segments.length - 1) || pending_gate?(payload)
        end

        def segment_at(index) = segments[index]

        def dom_id_at(index) = Rbrun::Sessions::Segment::Component.dom_id_for(*segments[index])

        def segment_index_for(message)
          anchor = message.tool_result? ? paired_use(message) : message
          return nil unless anchor

          segments.index do |kind, payload|
            kind == :tools ? payload.any? { |m| m.id == anchor.id } : payload.id == anchor.id
          end
        end

        def anchor?(message)
          return false if message.tool_result?
          return true if message.event_type.in?(%w[text internal])

          idx = segment_index_for(message)
          return false unless idx

          kind, payload = segments[idx]
          kind == :tools && payload.first.id == message.id
        end

        private

        def rows = @messages.reject { |m| m.role == "user" }

        def flush(out, run) = (out << [ :tools, run ] if run.any?)

        def pending_gate?(run) = run.any? { |m| m.respond_to?(:approval_pending?) && m.approval_pending? }

        def paired_use(result)
          rows.find { |m| m.tool_use? && m.tool_use_id == result.tool_use_id }
        end
      end
    end
  end
end
