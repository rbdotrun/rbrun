module Rbrun
  # Per-[worktree, name] exposure of a service: the intent flags (previewed / shared_public) and the
  # stable single-label preview token. It is the ADDRESS of one worktree's service — a preview host
  # (<token>-preview.<domain>) resolves through here to exactly one sandbox, never guessing across
  # worktrees. Survives the repo_services_start reset (only ServiceRun is destroyed), so a shared link
  # never rotates.
  class ServiceExposure < ApplicationRecord
    include Rbrun::Tenanted

    belongs_to :worktree, class_name: "Rbrun::Worktree"
    before_validation :inherit_tenant, on: :create

    validates :name, presence: true

    # The live run this exposure addresses — in THIS worktree's sandbox, unambiguously.
    def live_run = worktree.service_runs.find_by(name: name, status: "running")

    # Mint the single-label handle once; stable thereafter.
    def ensure_preview_token!
      update!(preview_token: SecureRandom.urlsafe_base64(6)) if preview_token.blank?
      preview_token
    end

    def preview_host
      return nil if preview_token.blank?

      Rbrun::PreviewDomain.host_for(preview_token)
    end

    # The user-facing preview URL. The host-provided edge URL wins (control plane owns the edge);
    # otherwise the engine's own single-label host. nil until one exists.
    def preview_url
      return edge_url if edge_url.present?
      return nil if preview_host.nil?

      "https://#{preview_host}"
    end

    private

    def inherit_tenant = self[Rbrun.config.tenancy_key] ||= worktree&.tenant
  end
end
