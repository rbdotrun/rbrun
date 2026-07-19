module Rbrun
  # An immutable snapshot of a skill folder: the whole folder as one gzipped-tar `archive`, keyed by
  # its content `digest`. `source` records where it came from (a config file, inline config, or a
  # future in-UI edit). The runtime stages a skill's `current_version` archive.
  class SkillVersion < ApplicationRecord
    belongs_to :skill, class_name: "Rbrun::Skill"

    enum :source, { file: "file", inline: "inline", ui: "ui" }, validate: true

    validates :digest, presence: true
    validates :archive, presence: true
  end
end
