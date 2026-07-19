module Rbrun
  # A capability the agent reads off its workspace — a folder (SKILL.md + files) stored and versioned
  # in rbrun's own DB. File/inline config only SEED this; the agent stages the `current_version` from
  # here, never from files. Content-addressed versions make seeding idempotent and diffs exact.
  #
  # Divergence: when an authored source differs from `current_version`, the seeder sets
  # `divergence_digest` (a warning) but never touches `current`. Resolution is explicit —
  # `promote!` (adopt the source as a new current version) or `keep_stored!` (keep current, remember
  # the reviewed digest so it stops warning until the source changes again).
  class Skill < ApplicationRecord
    include Rbrun::Tenanted

    has_many :versions, class_name: "Rbrun::SkillVersion", dependent: :destroy
    belongs_to :current_version, class_name: "Rbrun::SkillVersion", optional: true

    validates :slug, presence: true
    validates :name, presence: true

    def diverged? = divergence_digest.present?

    # Adopt an authored source as the live version: find-or-create the version, point `current` at it,
    # and clear both divergence flags. Idempotent on digest.
    def promote!(digest:, archive:, source:)
      transaction do
        version = versions.find_or_create_by!(digest: digest) { |v| v.archive = archive; v.source = source }
        update!(current_version: version, divergence_digest: nil, dismissed_digest: nil)
        version
      end
    end

    # Keep the stored `current` and remember that this authored digest was reviewed-and-declined, so
    # the seeder stops warning until the source changes to a new digest.
    def keep_stored!(digest:)
      update!(dismissed_digest: digest, divergence_digest: nil)
    end
  end
end
