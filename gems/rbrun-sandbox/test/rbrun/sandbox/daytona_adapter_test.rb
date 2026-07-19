require "test_helper"

class DaytonaAdapterTest < Minitest::Test
  # A hand fake standing in for Daytona::Client, recording calls and returning canned wire shapes.
  class FakeClient
    attr_reader :calls

    def initialize = @calls = []
    def find_or_create(_labels) = { "id" => "box-1", "state" => "started" }

    def exec(_id, command, timeout: 60)
      @calls << [ :exec, command, timeout ]
      command.include?("boom") ? { "exitCode" => 2, "result" => "nope" } : { "exitCode" => 0, "result" => "ok\n" }
    end

    def download(_id, path) = "contents-of-#{path}"
    def create_folder(_id, path, _mode = "755") = @calls << [ :create_folder, path ]
    def upload(_id, path, _source) = @calls << [ :upload, path ]
    def destroy(_id) = @calls << [ :destroy ]
    def create_session(_id, sid) = @calls << [ :create_session, sid ]
    def session_exec(_id, _sid, _command) = "cmd-9"
    def session_input(_id, _sid, _cid, data) = @calls << [ :session_input, data ]
    def session_command(_id, _sid, _cid) = { "exitCode" => 0 }
  end

  def build(client = FakeClient.new)
    Rbrun::Sandbox::Daytona.new(config: { api_key: "k", api_url: "u" }, labels: { session: 1 }, client: client)
  end

  def test_config_fails_fast_without_api_key
    assert_raises(Rbrun::Sandbox::Error) do
      Rbrun::Sandbox::Daytona.new(config: { api_url: "u" }, labels: {})
    end
  end

  def test_exec_normalizes_to_exec_result
    result = build.exec("echo ok")
    assert_instance_of Rbrun::Sandbox::ExecResult, result
    assert result.success?
    assert_equal "ok\n", result.stdout
  end

  def test_exec_bang_raises_on_nonzero
    assert_raises(Rbrun::Sandbox::Error) { build.exec!("boom") }
  end

  def test_exist_uses_exit_code
    adapter = build
    assert adapter.exist?("/some/path")            # exec exit 0 → true
    refute adapter.exist?("/boom/path")            # exec exit 2 → false
  end

  def test_write_creates_folder_then_uploads
    client = FakeClient.new
    build(client).write("/w/dir/a.txt", "hello")
    assert_includes client.calls.map(&:first), :create_folder
    assert_includes client.calls.map(&:first), :upload
  end

  def test_session_delegates_with_box_id
    client = FakeClient.new
    adapter = build(client)
    adapter.session_create("s1")
    assert_equal "cmd-9", adapter.session_exec("s1", "run")
    adapter.session_input("s1", "cmd-9", "data")
    assert_equal 0, adapter.session_command("s1", "cmd-9")["exitCode"]
    assert_includes client.calls, [ :create_session, "s1" ]
  end

  def test_destroy_resets_the_box
    client = FakeClient.new
    build(client).destroy!
    assert_includes client.calls, [ :destroy ]
  end
end
