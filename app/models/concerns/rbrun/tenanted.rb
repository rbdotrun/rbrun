module Rbrun
  # Roots every engine record to a tenant slug. MANDATORY: the column is NOT NULL. Its NAME is
  # configurable (Rbrun.config.tenancy_key, default "tenant"); the default slug value is "rbrun".
  module Tenanted
    extend ActiveSupport::Concern

    included do
      scope :for_tenant, ->(slug) { where(Rbrun.config.tenancy_key => slug) }
    end

    def tenant = self[Rbrun.config.tenancy_key]
  end
end
