require "test_helper"
require "tmpdir"

module Rbrun
  class SkillSeederTest < ActiveSupport::TestCase
    FILES  = { "SKILL.md" => "# v1\n" }.freeze
    FILES2 = { "SKILL.md" => "# v2\n" }.freeze

    def dig(files) = Rbrun::SkillArchive.digest_files(files)
    def inline(slug, files) = { slug: slug, name: slug, files: files, source: :inline }
    def seed(authored, tenant: "rbrun") = Rbrun::SkillSeeder.new(tenant: tenant, authored: authored).call

    def existing(slug: "pdf", files: FILES)
      skill = Rbrun::Skill.create!(tenant: "rbrun", slug: slug, name: slug)
      skill.promote!(digest: dig(files), archive: Rbrun::SkillArchive.pack_files(files), source: :inline)
      skill
    end

    test "a new slug is created with a first current version" do
      results = seed([ inline("pdf", FILES) ])
      assert_equal [ :created ], results.map(&:status)
      assert Rbrun::Skill.for_tenant("rbrun").find_by(slug: "pdf")&.current_version
    end

    test "identical authored content is unchanged" do
      existing
      assert_equal [ :unchanged ], seed([ inline("pdf", FILES) ]).map(&:status)
    end

    test "a changed source diverges without touching current" do
      skill = existing
      results = seed([ inline("pdf", FILES2) ])
      assert_equal [ :diverged ], results.map(&:status)
      assert_equal dig(FILES2), skill.reload.divergence_digest
      assert_equal dig(FILES),  skill.current_version.digest, "current is untouched"
    end

    test "a source matching the dismissed digest does not re-warn" do
      skill = existing
      skill.keep_stored!(digest: dig(FILES2))
      assert_equal [ :unchanged ], seed([ inline("pdf", FILES2) ]).map(&:status)
      assert_nil skill.reload.divergence_digest
    end

    test "a folder without SKILL.md is an issue, not a crash" do
      assert_equal [ :issue ], seed([ inline("bad", { "readme.txt" => "x" }) ]).map(&:status)
    end

    test "from_config assembles skills_path folders + inline config" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "from-file"))
        File.write(File.join(root, "from-file", "SKILL.md"), "# file\n")
        cfg = Rbrun::Config.new
        cfg.skills_path = root
        cfg.skill "from-inline", "# inline\n"

        statuses = Rbrun::SkillSeeder.from_config(cfg, tenant: "rbrun").call.map(&:status)
        assert_equal [ :created, :created ], statuses
        assert Rbrun::Skill.for_tenant("rbrun").exists?(slug: "from-file")
        assert Rbrun::Skill.for_tenant("rbrun").exists?(slug: "from-inline")
      end
    end
  end
end
