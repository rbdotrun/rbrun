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

    # Read a blob straight into a { relative-path => bytes } map (in-memory unpack).
    def files(blob)
      Gem::Package::TarReader.new(StringIO.new(Zlib.gunzip(blob))).each_with_object({}) do |entry, map|
        # TarReader returns ASCII-8BIT bytes; skill files are UTF-8 text. Re-tag as UTF-8 so the content
        # renders in the UI (no BINARY/UTF-8 buffer clash) AND the digest matches read_dir's UTF-8 bytes
        # (otherwise a skill with multibyte chars falsely reads as "diverged").
        map[entry.full_name] = entry.read.force_encoding("UTF-8") if entry.file?
      end
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
        # UTF-8 (not binread's ASCII-8BIT) so it matches files() and renders — bytes are unchanged, so the
        # content digest is identical; this just keeps the encoding consistent across pack/unpack.
        map[path.delete_prefix("#{root}/")] = File.binread(path).force_encoding("UTF-8")
      end
    end
  end
end
