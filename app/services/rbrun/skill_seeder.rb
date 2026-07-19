module Rbrun
  # Seeds authored skills (config files + inline) into the DB — the one place file/inline becomes a
  # DB Skill. It COMPARES and never clobbers: an authored source that differs from a skill's current
  # version is flagged (divergence_digest) and warned, never applied. Idempotent by content digest.
  #
  #   SkillSeeder.from_config(Rbrun.config, tenant: "rbrun").call  # => [Result(slug, status, message)]
  #
  # status: :created (new skill) · :unchanged (matches current or the dismissed digest) ·
  #         :diverged (differs — flagged + warned, current untouched) · :issue (bad folder/SKILL.md).
  class SkillSeeder
    Result = Data.define(:slug, :status, :message)

    # Assemble the authored seed sources: skills_path/<slug>/ folders (source: :file) then inline
    # config skills (source: :inline).
    def self.from_config(config, tenant:)
      authored = []
      dir = config.skills_path.to_s
      if dir.present? && Dir.exist?(dir)
        Dir.glob(File.join(dir, "*")).select { |d| File.directory?(d) }.sort.each do |folder|
          slug = File.basename(folder)
          authored << { slug: slug, name: slug, files: Rbrun::SkillArchive.read_dir(folder), source: :file }
        end
      end
      config.skills.each { |s| authored << s.merge(source: :inline) }
      new(tenant: tenant, authored: authored)
    end

    def initialize(tenant:, authored:)
      @tenant = tenant
      @authored = authored
    end

    def call = @authored.map { |authored| seed_one(authored) }

    private

    def seed_one(authored)
      slug, name, files, source = authored.values_at(:slug, :name, :files, :source)
      return Result.new(slug, :issue, "missing SKILL.md") unless files.is_a?(Hash) && files.key?("SKILL.md")

      digest = Rbrun::SkillArchive.digest_files(files)
      skill = Rbrun::Skill.for_tenant(@tenant).find_by(slug: slug)

      if skill.nil?
        skill = Rbrun::Skill.create!(tenant: @tenant, slug: slug, name: name)
        skill.promote!(digest: digest, archive: Rbrun::SkillArchive.pack_files(files), source: source)
        Result.new(slug, :created, nil)
      elsif [ skill.current_version&.digest, skill.dismissed_digest ].include?(digest)
        skill.update!(divergence_digest: nil) if skill.diverged?
        Result.new(slug, :unchanged, nil)
      else
        skill.update!(divergence_digest: digest)
        Result.new(slug, :diverged, "authored source differs from the stored version")
      end
    rescue StandardError => e
      Result.new(authored[:slug], :issue, e.message)
    end
  end
end
