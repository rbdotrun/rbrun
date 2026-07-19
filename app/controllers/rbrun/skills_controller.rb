module Rbrun
  # The Skills panel: surface the tenant's skills and, for any that diverge from their authored
  # source (or fail to parse), the diff + a Keep-stored / Reload resolution. Never clobbers — Reload
  # is an explicit, versioned adopt; Keep stored records the reviewed digest.
  class SkillsController < Rbrun::ApplicationController
    def index
      authored = authored_by_slug
      @rows = Rbrun::Skill.for_tenant(current_tenant).order(:slug).map { |s| row_for(s, authored[s.slug]) }
    end

    def reconcile
      skill = Rbrun::Skill.for_tenant(current_tenant).find_by!(slug: params[:slug])
      authored = authored_by_slug[skill.slug]
      apply(skill, authored) if authored && authored[:files].is_a?(Hash) && authored[:files].key?("SKILL.md")
      redirect_to rbrun.skills_path
    end

    private

    def authored_by_slug
      Rbrun::SkillSeeder.authored_from_config(Rbrun.config(current_tenant)).index_by { |a| a[:slug] }
    end

    def apply(skill, authored)
      digest = Rbrun::SkillArchive.digest_files(authored[:files])
      case params[:decision]
      when "reload"
        skill.promote!(digest: digest, archive: Rbrun::SkillArchive.pack_files(authored[:files]),
                       source: authored[:source])
      when "keep"
        skill.keep_stored!(digest: digest)
      end
    end

    # A view row: the skill + its live state (:clean | :diverged | :issue) + the SKILL.md bodies to diff.
    def row_for(skill, authored)
      current_md = skill.current_version && Rbrun::SkillArchive.files(skill.current_version.archive)["SKILL.md"]
      return { skill: skill, state: :clean, current_md: current_md, authored_md: nil } if authored.nil?

      files = authored[:files]
      return { skill: skill, state: :issue, current_md: current_md, authored_md: nil } unless files.is_a?(Hash) && files.key?("SKILL.md")

      digest = Rbrun::SkillArchive.digest_files(files)
      clean = [ skill.current_version&.digest, skill.dismissed_digest ].include?(digest)
      { skill: skill, state: clean ? :clean : :diverged, current_md: current_md, authored_md: files["SKILL.md"] }
    end
  end
end
