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

    # A skill's scenarios/examples ARE skill-bound workflows.
    has_many :workflows, class_name: "Rbrun::Workflow", dependent: :destroy

    validates :slug, presence: true
    validates :name, presence: true

    # The Skills table's grid tracks + rows-container id. Shared by the view (the table) and the row
    # broadcast (a standalone row must match the header's tracks). `dom_id(skill)` is each row's id.
    TABLE_TEMPLATE = "minmax(0,2fr) minmax(0,1.5fr) minmax(0,1fr) minmax(0,1fr)"
    ROWS_ID = "skills_rows"

    # The model streams its OWN row — append the first time it gains a version, replace on every later
    # promote. One row over the wire, never the whole table. No subscribers (boot seeding) ⇒ discarded.
    after_update_commit :broadcast_row, if: :saved_change_to_current_version_id?

    def diverged? = divergence_digest.present?

    # Live reconcile state against an authored config source's files (`nil` = no config source):
    # :clean (no source, or it matches current/dismissed) · :diverged (source differs) · :issue
    # (source unreadable — missing/broken SKILL.md). Domain logic — the panel asks the model, not a
    # presenter.
    def reconcile_status(authored_files)
      return :clean if authored_files.nil?
      return :issue unless authored_files.is_a?(Hash) && authored_files.key?("SKILL.md")

      digest = Rbrun::SkillArchive.digest_files(authored_files)
      [ current_version&.digest, dismissed_digest ].include?(digest) ? :clean : :diverged
    end

    # Adopt an authored source as the live version: find-or-create the version, point `current` at it,
    # and clear both divergence flags. Idempotent on digest.
    def promote!(digest:, archive:, source:)
      transaction do
        version = versions.find_or_create_by!(digest:) { |v| v.archive = archive; v.source = source }
        update!(current_version: version, divergence_digest: nil, dismissed_digest: nil)
        version
      end
    end

    # Keep the stored `current` and remember that this authored digest was reviewed-and-declined, so
    # the seeder stops warning until the source changes to a new digest.
    def keep_stored!(digest:)
      update!(dismissed_digest: digest, divergence_digest: nil)
    end

    private

      def broadcast_row
        stream = [ "rbrun", tenant, "skills" ]
        locals = { skill: self, template: TABLE_TEMPLATE }
        if current_version_id_before_last_save.nil? # first version → the row is new
          ::Turbo::StreamsChannel.broadcast_append_to(stream, target: ROWS_ID,
                                                      partial: "rbrun/skills/skill_row", locals:)
        else
          ::Turbo::StreamsChannel.broadcast_replace_to(stream,
                                                      target: ActionView::RecordIdentifier.dom_id(self),
                                                      partial: "rbrun/skills/skill_row", locals:)
        end
      end
  end
end
