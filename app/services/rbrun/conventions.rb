module Rbrun
  # The boot-enforced convention backbone. A "convention" is a DECLARED affordance on a subject that
  # must resolve, folder-per-unit, to a real unit — here: a gated tool's custom_approval! → its
  # Rbrun::Sessions::ToolsValidation::<Name>::Component card. A violation raises Conventions::Error and
  # fails the boot (ApplicationTool.validate_tool_approvals!) — the enforcement is the boot, not a test
  # that can be skipped or go stale.
  module Conventions
    Error = Class.new(StandardError)

    module_function

    # Resolve a folder-per-unit constant or raise. `const` is the FULL expected name; `base`, when
    # given, asserts the unit is a subclass.
    def resolve!(const, label, base: nil)
      unit = const.safe_constantize
      raise Error, "#{label}: expected #{const} (folder-per-unit) — not found" if unit.nil?

      if base && !(unit.is_a?(Class) && unit < base)
        raise Error, "#{label}: #{const} must be a Class < #{base} (folder-per-unit)"
      end

      unit
    end
  end
end
