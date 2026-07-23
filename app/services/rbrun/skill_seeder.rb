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

    # Engine-shipped skills (e.g. workflow-creator) — always seeded, like a built-in tool. A host can
    # still override one by authoring a same-slug skill (it seeds later, so it wins on divergence).
    BUILTIN_DIR = Rbrun::Engine.root.join("app/skills")

    def self.builtin_authored
      return [] unless BUILTIN_DIR.exist?

      Dir.glob(BUILTIN_DIR.join("*").to_s).select { |d| File.directory?(d) }.sort.map do |folder|
        slug = File.basename(folder)
        { slug:, name: slug, files: Rbrun::SkillArchive.read_dir(folder), source: :file }
      end
    end

    # Assemble the authored seed sources (non-mutating): engine built-ins first, then skills_path/<slug>/
    # folders (source: :file), then inline config skills (source: :inline). Also used by the Skills panel
    # for live diffs.
    def self.authored_from_config(config)
      authored = builtin_authored
      dir = config.skills_path.to_s
      if dir.present? && Dir.exist?(dir)
        Dir.glob(File.join(dir, "*")).select { |d| File.directory?(d) }.sort.each do |folder|
          slug = File.basename(folder)
          authored << { slug:, name: slug, files: Rbrun::SkillArchive.read_dir(folder), source: :file }
        end
      end
      config.skills.each { |s| authored << s.merge(source: :inline) }
      authored
    end

    def self.from_config(config, tenant:)
      new(tenant:, authored: authored_from_config(config))
    end

    # Boot hook (engine after_initialize): seed the self-host tenant from config. Fails LOUD on a
    # genuine skill error (:issue — an unparseable/malformed source) so a broken skill can't slip in
    # unnoticed, like the auth check. A :diverged skill only warns — raising would lock you out of the
    # Skills panel you'd use to reconcile it. No-ops (silent) when nothing is configured or the DB /
    # table isn't there yet (migrate/setup) — that's not an error.
    def self.seed_at_boot!
      return unless BUILTIN_DIR.exist? || Rbrun.config.skills_path.present? || Rbrun.config.skills.any?
      return unless Rbrun::Skill.table_exists?

      from_config(Rbrun.config, tenant: Rbrun::Config::DEFAULT_TENANT).call.each do |r|
        case r.status
        when :issue
          raise Rbrun::ConfigError, "skill '#{r.slug}' can't be seeded: #{r.message}"
        when :diverged
          Rails.logger.warn("[rbrun] skill '#{r.slug}' diverged from its source — reconcile in the Skills panel")
        end
      end
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished => e
      Rails.logger.debug { "[rbrun] skill seed skipped (#{e.class})" }
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
        skill = Rbrun::Skill.for_tenant(@tenant).find_by(slug:)

        if skill.nil?
          skill = Rbrun::Skill.create!(tenant: @tenant, slug:, name:)
          skill.promote!(digest:, archive: Rbrun::SkillArchive.pack_files(files), source:)
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
