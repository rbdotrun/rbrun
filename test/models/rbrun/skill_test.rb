require "test_helper"

module Rbrun
  class SkillTest < ActiveSupport::TestCase
    FILES  = { "SKILL.md" => "# v1\n" }.freeze
    FILES2 = { "SKILL.md" => "# v2\n" }.freeze

    def blob(files) = Rbrun::SkillArchive.pack_files(files)
    def dig(files)  = Rbrun::SkillArchive.digest_files(files)

    def make(slug: "pdf", tenant: "rbrun")
      skill = Rbrun::Skill.create!(tenant: tenant, slug: slug, name: slug)
      skill.promote!(digest: dig(FILES), archive: blob(FILES), source: :file)
      skill
    end

    test "promote! creates a version, points current, and clears both flags" do
      skill = Rbrun::Skill.create!(tenant: "rbrun", slug: "pdf", name: "PDF")
      skill.update!(divergence_digest: "x", dismissed_digest: "y")
      v = skill.promote!(digest: dig(FILES), archive: blob(FILES), source: :file)

      assert_equal v, skill.reload.current_version
      assert_equal 1, skill.versions.count
      assert_nil skill.divergence_digest
      assert_nil skill.dismissed_digest
      assert_predicate v, :file?
    end

    test "promote! is idempotent on digest (no duplicate version)" do
      skill = make
      assert_no_difference("Rbrun::SkillVersion.count") do
        skill.promote!(digest: dig(FILES), archive: blob(FILES), source: :file)
      end
    end

    test "keep_stored! records dismissed_digest and clears divergence" do
      skill = make
      skill.update!(divergence_digest: dig(FILES2))
      skill.keep_stored!(digest: dig(FILES2))

      assert_equal dig(FILES2), skill.reload.dismissed_digest
      assert_nil skill.divergence_digest
      assert_equal FILES, unpack_current(skill), "current version is unchanged"
    end

    test "for_tenant scopes; slug is unique per tenant" do
      make(slug: "pdf", tenant: "rbrun")
      make(slug: "pdf", tenant: "acme")
      assert_equal 1, Rbrun::Skill.for_tenant("rbrun").where(slug: "pdf").count
      assert_equal 1, Rbrun::Skill.for_tenant("acme").where(slug: "pdf").count
      assert_raises(ActiveRecord::RecordNotUnique) do
        Rbrun::Skill.create!(tenant: "rbrun", slug: "pdf", name: "dup")
      end
    end

    test "promoting appends the row the first time, replaces it after" do
      skill = Rbrun::Skill.create!(tenant: "acme", slug: "greet", name: "Greet")
      stream = [ "rbrun", "acme", "skills" ]

      first = capture_turbo_stream_broadcasts(stream) do
        skill.promote!(digest: "d1", archive: Rbrun::SkillArchive.pack_files({ "SKILL.md" => "hi" }), source: :ui)
      end
      assert_equal 1, first.size
      assert_equal "append", first.first["action"]
      assert_equal Rbrun::Skill::ROWS_ID, first.first["target"]

      second = capture_turbo_stream_broadcasts(stream) do
        skill.promote!(digest: "d2", archive: Rbrun::SkillArchive.pack_files({ "SKILL.md" => "hi2" }), source: :ui)
      end
      assert_equal "replace", second.first["action"]
      assert_equal ActionView::RecordIdentifier.dom_id(skill), second.first["target"]
    end

    def unpack_current(skill)
      require "tmpdir"
      Dir.mktmpdir do |dir|
        Rbrun::SkillArchive.unpack(skill.reload.current_version.archive, into: dir)
        Rbrun::SkillArchive.read_dir(dir)
      end
    end
  end
end
