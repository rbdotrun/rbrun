module Rbrun
  # A first-class, versioned deliverable the agent produced (a report, a document). NO OWNERSHIP:
  # provenance lives on each version's `message`; session/worktree/context are always DERIVED via
  # `version.message.session`, never stored here. Tenant is scope only (invariant #8).
  class Artifact < ApplicationRecord
    include Rbrun::Tenanted

    has_many :versions, class_name: "Rbrun::ArtifactVersion", dependent: :destroy
    belongs_to :current_version, class_name: "Rbrun::ArtifactVersion", optional: true

    validates :name, presence: true

    # Persist one workspace file as the artifact's next version. Find-or-create the artifact (scoped to
    # the tenant when re-versioning an existing one), append a numbered immutable version stamped with
    # the producing turn's `message`, attach the blob, and advance `current_version`. Each call is a NEW
    # version; history is never mutated. The tenant column is configurable, so it is set by name
    # (`Rbrun.config.tenancy_key`) rather than assuming a literal `tenant:` attribute.
    def self.append_version!(tenant:, message:, io:, filename:, name: nil, artifact_id: nil)
      transaction do
        artifact =
          if artifact_id
            for_tenant(tenant).find(artifact_id)
          else
            create!(Rbrun.config.tenancy_key => tenant, :name => name.presence || filename)
          end
        number  = artifact.versions.maximum(:number).to_i + 1
        version = artifact.versions.create!(number:, message:)
        version.file.attach(io:, filename:)
        artifact.update!(current_version: version)
        version
      end
    end
  end
end
