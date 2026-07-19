require "test_helper"
require "tempfile"

class LocalTest < Minitest::Test
  def setup
    @sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "local-#{Process.pid}" })
  end

  def teardown
    @sandbox&.destroy!
  end

  def test_exec_returns_normalized_result
    result = @sandbox.exec("echo hi")
    assert_instance_of Rbrun::Sandbox::ExecResult, result
    assert result.success?
    assert_equal "hi\n", result.stdout
  end

  def test_exec_bang_raises_on_failure
    assert_raises(Rbrun::Sandbox::Error) { @sandbox.exec!("exit 3") }
  end

  def test_write_read_exist
    @sandbox.write("dir/a.txt", "hello")
    assert @sandbox.exist?("dir/a.txt")
    assert_equal "hello", @sandbox.read("dir/a.txt")
    refute @sandbox.exist?("dir/missing.txt")
  end

  def test_upload_many_files
    src = Tempfile.new("rbrun-src")
    src.write("payload")
    src.close
    @sandbox.upload([ Rbrun::Sandbox::FileUpload.new(source: src.path, destination: "up/x.txt") ])
    assert_equal "payload", @sandbox.read("up/x.txt")
  ensure
    src&.unlink
  end

  def test_glob_lists_files_relative_sorted
    @sandbox.write("a.txt", "1")
    @sandbox.write("sub/b.txt", "2")
    assert_equal [ "a.txt", "sub/b.txt" ], @sandbox.glob(".")
  end

  def test_exec_stream_yields_lines
    lines = []
    result = @sandbox.exec_stream("printf 'l1\\nl2\\n'") { |line| lines << line }
    assert_equal [ "l1\n", "l2\n" ], lines
    assert result.success?
  end

  def test_destroy_removes_the_box
    @sandbox.write("x", "1")
    root = @sandbox.workspace
    @sandbox.destroy!
    refute File.exist?(root)
  end
end
