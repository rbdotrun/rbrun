module Rbrun
  # The worktree's deployment: which server (Hetzner) the app is deployed onto and at which DNS host. One
  # per worktree, so tools address it by the worktree —
  # never a free-floating name. Tenant is inherited from the worktree. Distinct from the worktree's dev
  # sandbox (Daytona): this is the deployed app's server.
  class DeployTarget < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create

    STATUSES = %w[pending provisioned deploying deployed failed torn_down].freeze
    validates :provider, :server_type, :region, :image, :host, presence: true
    validates :status, inclusion: { in: STATUSES }

    # The clickable live URL for this deployment (nil until a host exists).
    def url = host.present? ? "https://#{host}" : nil

    private

      def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
  end
end
