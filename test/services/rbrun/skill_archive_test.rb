require "test_helper"
require "tmpdir"

module Rbrun
  class SkillArchiveTest < ActiveSupport::TestCase
    FILES = { "SKILL.md" => "# hi\n", "sub/t.txt" => "data" }.freeze

    test "pack_files → unpack round-trips the folder" do
      blob = SkillArchive.pack_files(FILES)
      Dir.mktmpdir do |dir|
        SkillArchive.unpack(blob, into: dir)
        assert_equal "# hi\n", File.read(File.join(dir, "SKILL.md"))
        assert_equal "data", File.read(File.join(dir, "sub/t.txt"))
      end
    end

    test "digest_files is order-independent, content-stable, and change-sensitive" do
      d1 = SkillArchive.digest_files(FILES)
      d2 = SkillArchive.digest_files({ "sub/t.txt" => "data", "SKILL.md" => "# hi\n" })
      assert_equal d1, d2, "same content in any order ⇒ same digest"
      refute_equal d1, SkillArchive.digest_files(FILES.merge("SKILL.md" => "# changed\n"))
    end

    test "digest of a packed-then-unpacked dir equals digest_files (round-trip stable)" do
      blob = SkillArchive.pack_files(FILES)
      Dir.mktmpdir do |dir|
        SkillArchive.unpack(blob, into: dir)
        assert_equal SkillArchive.digest_files(FILES), SkillArchive.digest(dir)
      end
    end

    test "pack is a folder shortcut for pack_files" do
      Dir.mktmpdir do |src|
        FileUtils.mkdir_p(File.join(src, "sub"))
        File.write(File.join(src, "SKILL.md"), "# hi\n")
        File.write(File.join(src, "sub/t.txt"), "data")
        assert_equal SkillArchive.digest_files(FILES), SkillArchive.digest(src)
      end
    end
  end
end
