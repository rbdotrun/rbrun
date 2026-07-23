module Rbrun
  module Tools
    # Promote a skill the agent authored in its workspace into the tenant's skill store. A skill is a
    # FOLDER (SKILL.md + files); this reads it, packs it into one archive, and promotes it as the
    # tenant's current version — behind an approval gate, because a promoted skill is injected into
    # every future turn (unlike save_artifact, which is leaf output). `source: :ui` — authored in-app,
    # not from config — so the seeder's config reconcile leaves it alone.
    class SaveSkill < Rbrun::ApplicationTool
      needs_approval!

      description <<~TXT
        Promote a skill you authored into the skill store. A skill is a FOLDER containing a SKILL.md and
        any supporting files. Write that folder in your workspace first, then call this with the folder's
        workspace-relative `folder_path`. This requires the user's approval; on approval the folder
        becomes the tenant's current version of the skill (keyed by the folder name as the slug).
      TXT

      parameter :folder_path, type: "string", required: true,
                description: %(workspace-relative path to the skill FOLDER, e.g. "my-skill")

      def execute(folder_path:)
        files = read_folder(folder_path)
        return error("no files found under #{folder_path}") if files.empty?
        return error("a skill folder must contain a SKILL.md") unless files.key?("SKILL.md")

        slug   = File.basename(folder_path)
        name   = skill_name(files["SKILL.md"], slug)
        digest = Rbrun::SkillArchive.digest_files(files)

        skill = Rbrun::Skill.for_tenant(tenant).find_or_initialize_by(slug: slug)
        created = skill.new_record?
        skill.name = name
        skill.save!
        skill.promote!(digest: digest, archive: Rbrun::SkillArchive.pack_files(files), source: :ui)

        { "data" => { "slug" => slug, "name" => name, "digest" => digest,
                      "files" => files.keys.sort, "created" => created } }
      end

      private

      # Build the { relative_path => bytes } map from the workspace folder (glob + read per file).
      def read_folder(folder_path)
        session.sandbox.glob(folder_path).to_h do |rel|
          [ rel, session.sandbox.read(File.join(folder_path, rel)) ]
        end
      end

      # The skill's display name from SKILL.md frontmatter `name:` (read line-by-line like the SDK, not
      # strict YAML — a description may carry a colon), falling back to a titleized slug.
      def skill_name(md, slug)
        front = md.to_s[/\A---\n(.*?)\n---/m, 1]
        name  = front&.lines&.filter_map do |line|
          key, value = line.split(":", 2)
          value&.strip if key.strip == "name" && value
        end&.first
        name.presence || slug.tr("-_", " ").split.map(&:capitalize).join(" ")
      end
    end
  end
end
