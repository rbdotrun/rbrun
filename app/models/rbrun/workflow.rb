module Rbrun
  # A durable, reusable task procedure — label + goal + ordered steps. It OWNS its runs
  # (has_many :sessions); a Session is a disposable run of it. Never deleted by clearing a run.
  class Workflow < ApplicationRecord
    include Rbrun::Tenanted

    has_many :sessions, class_name: "Rbrun::Session", dependent: :nullify
    has_many :steps, -> { order(:position) }, class_name: "Rbrun::WorkflowStep",
             inverse_of: :workflow, dependent: :destroy

    # A skill-bound workflow IS that skill's scenario/example (skill_id set ⇒ scenario); showcase points
    # at the artifact its last run produced. Both optional — a plain conversation workflow leaves them nil.
    belongs_to :skill, class_name: "Rbrun::Skill", optional: true
    belongs_to :showcase_artifact_version, class_name: "Rbrun::ArtifactVersion", optional: true

    accepts_nested_attributes_for :steps, allow_destroy: true,
      reject_if: ->(a) { a[:title].blank? && a[:description].blank? }

    scope :scenarios, -> { where.not(skill_id: nil) }

    validates :label, presence: true

    # Portable, tenant-agnostic keyword search (sqlite + pg): case-insensitive LIKE across the text
    # columns. A pg host can later swap in weighted full-text without touching callers.
    scope :search, ->(query) {
      term = query.to_s.strip
      next none if term.empty?

      like = "%#{sanitize_sql_like(term).downcase}%"
      where("LOWER(label) LIKE :q OR LOWER(COALESCE(goal, '')) LIKE :q OR LOWER(COALESCE(description, '')) LIKE :q", q: like)
    }
  end
end
