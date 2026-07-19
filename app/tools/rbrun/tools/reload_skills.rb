module Rbrun
  module Tools
    # Re-stage the current skills from the store (DB) into the workspace. The source is always the
    # database — the current SkillVersion of each of the tenant's skills — never files or config.
    #
    # Timing: the SDK discovers skills at run init, so a mid-turn reload freshens
    # <workspace>/.claude/skills/ for the NEXT turn, not the running one. The description says so.
    class ReloadSkills < Rbrun::ApplicationTool
      description "Re-stage the current skills from the store into your workspace. Takes effect on your NEXT turn."

      def execute
        dest = File.join(session.sandbox.workspace, ".claude", "skills")
        count = 0
        Rbrun::Skill.for_tenant(tenant).where.not(current_version_id: nil).includes(:current_version).find_each do |skill|
          Rbrun::SkillArchive.files(skill.current_version.archive).each do |rel, bytes|
            session.sandbox.write(File.join(dest, skill.slug, rel), bytes)
          end
          count += 1
        end
        { "data" => { "reloaded" => count, "note" => "effective next turn" } }
      end
    end
  end
end
