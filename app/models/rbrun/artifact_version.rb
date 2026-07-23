module Rbrun
  # An immutable snapshot of an Artifact: one ActiveStorage blob (`file`), a per-artifact `number`, and
  # the `message` (the turn's lead user message) that produced it — the artifact's ONLY provenance link.
  # `content_type`/`byte_size` are read off the blob; there is no `kind` column.
  class ArtifactVersion < ApplicationRecord
    belongs_to :artifact, class_name: "Rbrun::Artifact"
    # Provenance, not ownership: optional + on_delete :nullify so a version outlives its producing
    # message (the artifact must survive its session's deletion).
    belongs_to :message, class_name: "Rbrun::SessionMessage", optional: true

    has_one_attached :file

    validates :number, presence: true, uniqueness: { scope: :artifact_id }

    delegate :content_type, :byte_size, to: :file, allow_nil: true
  end
end
