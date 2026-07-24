require "yaml"

module Rbrun
  # Fields ⇄ SKILL.md. The ONE seam that assembles a SKILL.md (YAML frontmatter + markdown body) from
  # the editor's fields and parses one back. The archive (SkillVersion#archive) stays the source of a
  # skill's content — this only (de)serializes its SKILL.md. Card + soft-hint keys live in the
  # frontmatter, NEVER in a column on Skill.
  class SkillForm
    # Frontmatter scalar keys, in emit order (body is separate — it's the markdown after the fences).
    FRONT_KEYS  = %i[name description label tagline icon kind example].freeze
    LIST_KEYS   = %i[preferred_skills preferred_tools].freeze
    SCALAR_KEYS = (FRONT_KEYS + %i[body]).freeze

    attr_accessor(*SCALAR_KEYS, *LIST_KEYS)

    def initialize(attrs = {})
      h = attrs.respond_to?(:to_unsafe_h) ? attrs.to_unsafe_h : attrs.to_h
      h = h.symbolize_keys
      SCALAR_KEYS.each { |k| public_send("#{k}=", h[k].to_s) }
      LIST_KEYS.each   { |k| public_send("#{k}=", Array(h[k]).map { |v| v.to_s.strip }.reject(&:blank?)) }
    end

    # The assembled SKILL.md: frontmatter (only non-blank keys) then the body.
    def skill_md = "#{frontmatter}\n\n#{body.to_s.strip}\n"

    # Parse a SKILL.md string back into a form (frontmatter → fields, remainder → body).
    def self.parse(md)
      front, body = split(md)
      data = front.present? ? (YAML.safe_load(front) || {}) : {}
      new(data.merge("body" => body.to_s.strip))
    end

    # Parse a SkillVersion's archived SKILL.md. A nil version yields an empty form (the New form).
    def self.from_version(version)
      return new if version.nil?

      md = Rbrun::SkillArchive.files(version.archive)["SKILL.md"].to_s
      parse(md)
    end

    # Split "---\n<frontmatter>\n---\n<body>" → [frontmatter, body]. No fence ⇒ ["", whole string].
    def self.split(md)
      if (m = md.to_s.match(/\A---\s*\n(.*?)\n---\s*\n?(.*)\z/m))
        [ m[1], m[2] ]
      else
        [ "", md.to_s ]
      end
    end
    private_class_method :split

    private

      def frontmatter
        h = {}
        FRONT_KEYS.each { |k| v = public_send(k); h[k.to_s] = v if v.present? }
        LIST_KEYS.each  { |k| v = public_send(k); h[k.to_s] = v if v.any? }
        yaml = YAML.dump(h).delete_prefix("---\n").strip
        "---\n#{yaml}\n---"
      end
  end
end
