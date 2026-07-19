require "rubygems/package"
require "zlib"
require "stringio"
require "digest"
require "fileutils"

module Rbrun
  # A skill folder ⇄ one gzipped-tar blob, plus a content digest. A skill is a folder (SKILL.md +
  # resource files); this is the single round-trip used to store it (SkillVersion#archive) and to
  # materialize it back into a sandbox workspace at stage time.
  #
  # The blob's BYTES are not a pure function of the content — gzip stamps an mtime — so never compare
  # two archives for equality. Version identity and diffing use #digest/#digest_files instead: a
  # SHA256 over the sorted (relative-path, bytes) pairs, which IS content-stable.
  module SkillArchive
    module_function

    # Pack a folder's files into a gzipped-tar blob (paths relative to `dir`).
    def pack(dir) = pack_files(read_dir(dir))

    # Pack an in-memory { "relative/path" => bytes } map into the same blob format.
    def pack_files(files)
      tar = StringIO.new
      Gem::Package::TarWriter.new(tar) do |writer|
        files.keys.sort.each do |rel|
          content = files[rel].to_s
          writer.add_file_simple(rel, 0o644, content.bytesize) { |io| io.write(content) }
        end
      end
      Zlib.gzip(tar.string)
    end

    # Recreate the folder from a blob under `into/`. Returns `into`.
    def unpack(blob, into:)
      FileUtils.mkdir_p(into)
      Gem::Package::TarReader.new(StringIO.new(Zlib.gunzip(blob))) do |reader|
        reader.each do |entry|
          next unless entry.file?

          dest = File.join(into, entry.full_name)
          FileUtils.mkdir_p(File.dirname(dest))
          File.binwrite(dest, entry.read)
        end
      end
      into
    end

    # Content digest of a folder / of an in-memory file map — stable across pack/unpack.
    def digest(dir) = digest_files(read_dir(dir))

    def digest_files(files)
      payload = files.keys.sort.map { |rel| "#{rel}\0#{files[rel]}" }.join("\0\0")
      Digest::SHA256.hexdigest(payload)
    end

    # Read a folder into a { relative-path => bytes } map (files only).
    def read_dir(dir)
      root = File.expand_path(dir)
      Dir.glob(File.join(root, "**", "*")).select { |f| File.file?(f) }.each_with_object({}) do |path, map|
        map[path.delete_prefix("#{root}/")] = File.binread(path)
      end
    end
  end
end
