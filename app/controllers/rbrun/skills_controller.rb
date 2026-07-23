module Rbrun
  # The Skills panel: surface the tenant's skills, author/edit them through a form (each Save promotes a
  # new SkillVersion), and reconcile any that diverge from their authored source. Never clobbers —
  # Reload is an explicit, versioned adopt; Keep stored records the reviewed digest.
  class SkillsController < Rbrun::ApplicationController
    helper_method :skill_options, :tool_options

    def index
      @skills = Rbrun::Skill.for_tenant(current_tenant).order(:slug)
      @authored = authored_by_slug
    end

    def new
      @skill = nil
      @form  = Rbrun::SkillForm.new
    end

    def create
      @form = Rbrun::SkillForm.new(form_params)
      slug  = @form.name.to_s.parameterize
      if slug.blank?
        @skill = nil
        flash.now[:alert] = "A skill needs a name."
        return render :new, status: :unprocessable_entity
      end

      skill = Rbrun::Skill.new(tenant: current_tenant, slug:, name: @form.name)
      files = { "SKILL.md" => @form.skill_md }
      skill.save!
      skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                     archive: Rbrun::SkillArchive.pack_files(files), source: :ui)
      redirect_to rbrun.edit_skill_path(skill.slug), notice: "Skill created."
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      @skill = nil
      flash.now[:alert] = "Couldn't create the skill: #{e.message}"
      render :new, status: :unprocessable_entity
    end

    def edit
      @skill   = find_skill
      @version = params[:version].present? ? @skill.versions.find(params[:version]) : @skill.current_version
      @form    = Rbrun::SkillForm.from_version(@version)
    end

    def update
      @skill = find_skill
      @form  = Rbrun::SkillForm.new(form_params)
      base   = @skill.current_version ? Rbrun::SkillArchive.files(@skill.current_version.archive) : {}
      files  = base.merge("SKILL.md" => @form.skill_md)

      @skill.update!(name: @form.name.presence || @skill.name)
      @skill.promote!(digest: Rbrun::SkillArchive.digest_files(files),
                      archive: Rbrun::SkillArchive.pack_files(files), source: :ui)
      redirect_to rbrun.edit_skill_path(@skill.slug), notice: "New version promoted."
    end

    def reconcile
      skill = Rbrun::Skill.for_tenant(current_tenant).find_by!(slug: params[:slug])
      authored = authored_by_slug[skill.slug]
      apply(skill, authored) if authored && authored[:files].is_a?(Hash) && authored[:files].key?("SKILL.md")
      redirect_to rbrun.skills_path
    end

    private

      def find_skill
        Rbrun::Skill.for_tenant(current_tenant).find_by!(slug: params[:slug])
      end

      def form_params
        params.require(:skill).permit(:name, :label, :tagline, :icon, :kind, :example,
                                      :description, :body, preferred_skills: [], preferred_tools: [])
      end

      # Soft-hint options (author/display only). Skills = the tenant's slugs; tools = the tool manifest.
      def skill_options = Rbrun::Skill.for_tenant(current_tenant).order(:slug).pluck(:name, :slug)
      def tool_options  = Rbrun::ApplicationTool.manifest.map { |t| [ t["name"], t["name"] ] }

      def authored_by_slug
        Rbrun::SkillSeeder.authored_from_config(Rbrun.config(current_tenant)).index_by { |a| a[:slug] }
      end

      def apply(skill, authored)
        digest = Rbrun::SkillArchive.digest_files(authored[:files])
        case params[:decision]
        when "reload"
          skill.promote!(digest:, archive: Rbrun::SkillArchive.pack_files(authored[:files]),
                         source: authored[:source])
        when "keep"
          skill.keep_stored!(digest:)
        end
      end
  end
end
