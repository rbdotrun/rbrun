module Rbrun
  module Sessions
    module Segment
      # ONE segment of a turn's timeline, rendered on its own so it can be live-updated in isolation:
      # a :prose block, an :internal note, or a :tools run (the work accordion). Keyed by a stable
      # #dom_id so a live event replaces only its node (live == reload).
      class Component < Rbrun::ApplicationViewComponent
        include Rbrun::SessionsHelper

        def initialize(kind:, payload:, results: {}, open: false)
          @kind = kind
          @payload = payload
          @results = results
          @open = open
        end

        attr_reader :kind, :payload, :open

        # A run is keyed by its FIRST call's row id; a prose/internal block by its own row id. A class
        # method so the Timeline (which targets a live replace) and the rendered node agree by construction.
        def self.dom_id_for(kind, payload)
          kind == :tools ? "work_#{payload.first.id}" : "seg_#{payload.id}"
        end

        def dom_id = self.class.dom_id_for(kind, payload)

        def steps
          @steps ||= payload.map do |use|
            res = @results[use.tool_use_id]
            {
              id: use.id,
              row: use,
              tool_use_id: use.tool_use_id,
              name: use.payload["name"],
              input: use.payload["input"],
              result: res&.payload&.dig("result"),
              error: !!res&.payload&.dig("is_error"),
              approval: use.approval_status,
              running: res.nil? && use.approval_status.nil?
            }
          end
        end

        APPROVAL_BADGES = {
          "approved"  => { icon: "check", style: "bg-green-100 text-green-700", label: "Approved" },
          "rejected"  => { icon: "x", style: "bg-red-100 text-red-700", label: "Refused" },
          "cancelled" => { icon: "clock", style: "bg-slate-200 text-slate-600", label: "Cancelled" }
        }.freeze

        def approval_badge(status) = APPROVAL_BADGES[status]

        HINT_MAX = 70

        def tool_hint(input)
          return "" unless input.is_a?(Hash)

          input.map do |key, value|
            text = value.to_s
            text.length > HINT_MAX ? "#{key}: #{helpers.number_to_human_size(text.bytesize)}" : "#{key}: #{text}"
          end.join(" · ").truncate(110)
        end
      end
    end
  end
end
