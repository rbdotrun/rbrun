module Rbrun
  module Mcp
    # Keep the total exposed tool count under the SDK's schema-deferral line — past it the SDK ships
    # tool names WITHOUT schemas and the model calls them blind (the `enum_options: received undefined`
    # failure). External servers return their FULL tools/list regardless of granted scope, so we reduce
    # and cap BEFORE materialization. Three layers, and never silent — every drop is logged:
    #   1. blocked tools removed (from tool_permissions)
    #   2. per-server `tools` allowlist honored (nil ⇒ all — uncountable, warned, runtime-backstopped)
    #   3. hard per-turn cap; on overflow drop lowest-priority first (always_allow > needs_approval),
    #      then later-declared servers/tools.
    #
    # CEILING is the single source of the number; the runtime is handed it so client.ts can't drift.
    module ToolBudget
      CEILING = 40
      BUILTIN_COUNT = 7 # the SDK built-ins client.ts exposes (Skill, Read, Write, Edit, Glob, Grep, Bash)
      PRIORITY = { "always_allow" => 2, "needs_approval" => 1 }.freeze

      module_function

      # Returns the specs with `tools` reduced to the effective exposed set.
      def apply(specs, builtin_count:, rbrun_count:, ceiling: CEILING)
        reduced = specs.map { |spec| spec.with(tools: exposed(spec)) }
        reduced.each do |spec|
          Rails.logger.warn("[rbrun] mcp '#{spec.name}' exposes ALL tools — can't pre-budget; runtime ceiling backstops") if spec.tools.nil?
        end

        budget = [ ceiling - builtin_count - rbrun_count, 0 ].max
        # `tools: nil` means ALL of that server's tools — an UNKNOWABLE count until the server answers,
        # so it is deliberately not summed here (it is not zero; it is unknown). That is only safe
        # because the ceiling is now genuinely enforced at the one place the real count exists:
        # AgentTurn hands CEILING to the runtime and client.ts truncates the allowed-tool list to it.
        # Without that backstop this sum silently under-counts and the cap never fires.
        known = reduced.sum { |spec| spec.tools&.size || 0 }
        return reduced if known <= budget

        dropped = rank(reduced).first(known - budget)
        dropped.each { |e| Rails.logger.warn("[rbrun] mcp tool dropped for tool budget: #{reduced[e[:si]].name}/#{e[:name]}") }

        by_spec = dropped.group_by { |e| e[:si] }
        reduced.each_with_index.map do |spec, si|
          drops = (by_spec[si] || []).map { |e| e[:name] }
          drops.empty? ? spec : spec.with(tools: spec.tools - drops)
        end
      end

      # Explicit allowlist minus blocked; nil (all) stays nil (uncountable here).
      def exposed(spec)
        return nil if spec.tools.nil?

        spec.tools.reject { |tool| perm(spec, tool) == "blocked" }
      end

      def perm(spec, tool)
        tp = (spec.tool_permissions || {}).to_h { |k, v| [ k.to_s, v.to_s ] }
        tp[tool.to_s] || tp["default"] || "always_allow"
      end

      # Droppable tools, lowest-priority first, then later-declared servers/tools first.
      def rank(specs)
        specs.each_with_index.flat_map do |spec, si|
          (spec.tools || []).each_with_index.map do |tool, ti|
            { si:, ti:, name: tool, prio: PRIORITY.fetch(perm(spec, tool), 2) }
          end
        end.sort_by { |e| [ e[:prio], -e[:si], -e[:ti] ] }
      end
    end
  end
end
