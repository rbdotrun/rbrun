module Rbrun
  # The Skills panel: surface the tenant's skills and, for any that diverge from their authored
  # source (or fail to parse), the diff + a Keep-stored / Reload resolution. Never clobbers — Reload
  # is an explicit, versioned adopt; Keep stored records the reviewed digest.
  class SkillsController < Rbrun::ApplicationController
    # The tenant's dedicated skill-authoring worktree — a bare sandbox (never provisioned/cloned), one
    # per tenant, under which each "New skill" click opens a fresh create-skill conversation.
    SKILLS_REPO = "rbrun/skills"

    def index
      @skills = Rbrun::Skill.for_tenant(current_tenant).order(:slug)
      @authored = authored_by_slug
    end

    # Open a create-skill conversation in the app-wide drawer: a fresh session under the tenant's
    # skills worktree, steered to the create-skill skill via preferred_skills.
    def build
      worktree = Rbrun::Worktree.for_tenant(current_tenant).create_with(bare: true).find_or_create_by!(repo: SKILLS_REPO)
      @session = worktree.sessions.create!(preferred_skills: %w[create-skill])
      render :build, layout: false
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
  end
end
