module Rbrun
  module Tools
    # Who the turn works for: the current tenant slug and session id. The agent is told to call this
    # first (see Rbrun.config.system_prompt). Generic — hosts add richer identity tools of their own.
    class Identity < Rbrun::ApplicationTool
      description "Returns who you are working for: the current tenant and session id. Call this first."

      def execute = { "data" => { "tenant" => tenant, "session_id" => session&.id } }
    end
  end
end
