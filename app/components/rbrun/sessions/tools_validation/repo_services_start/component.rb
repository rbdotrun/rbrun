module Rbrun
  module Sessions
    module ToolsValidation
      module RepoServicesStart
        # The repo_services_start gate card: the proposed services + the shared yes/no approval actions
        # while pending; a short recap once decided.
        class Component < Rbrun::Sessions::ToolsValidation::Base
          private

          def services = Array(input["services"])
          def decided? = !@call.approval_pending?
          def approved? = @call.approval_approved?
        end
      end
    end
  end
end
