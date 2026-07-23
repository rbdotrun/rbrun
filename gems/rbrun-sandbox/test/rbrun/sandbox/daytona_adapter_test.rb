require "test_helper"

# The adapter over the REAL Daytona::Client, with only the WIRE stubbed (WebMock). No hand-rolled fake
# client: a fake stands in for the very code that builds requests and parses responses, so it hides
# exactly the bugs these tests exist to catch (e.g. session_create 409s on Daytona).
class DaytonaAdapterTest < Minitest::Test
  API = "https://api.test"
  TOOLBOX = "https://proxy.app.daytona.io/toolbox"
  BOX = "box-1"

  def setup
    # Box lookup: list by labels, then confirm the candidate by id.
    stub_request(:get, "#{API}/sandbox")
      .with(query: { "labels" => { session: "1" }.to_json })
      .to_return(json({ "items" => [ { "id" => BOX, "state" => "started", "createdAt" => "1" } ] }))
    stub_request(:get, "#{API}/sandbox/#{BOX}")
      .to_return(json({ "id" => BOX, "state" => "started" }))
  end

  def json(body, status: 200)
    { status:, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  def build
    Rbrun::Sandbox::Daytona.new(config: { api_key: "k", api_url: API }, labels: { session: 1 })
  end

  def stub_exec(exit_code: 0, result: "ok\n")
    stub_request(:post, "#{TOOLBOX}/#{BOX}/process/execute")
      .to_return(json({ "exitCode" => exit_code, "result" => result }))
  end

  # A box that VANISHES while starting (Daytona kills it server-side mid-start) is transient — the client
  # must discard it and create a fresh one, not crash the turn. This is the exact flake that aborted the
  # lifecycle dogfood's second turn.
  def test_create_retries_when_the_box_vanishes_while_starting
    # No existing box for these labels — force the create path.
    stub_request(:get, "#{API}/sandbox").with(query: { "labels" => { session: "1" }.to_json })
                                         .to_return(json({ "items" => [] }))
    # Snapshot already built.
    stub_request(:get, %r{#{API}/snapshots/}).to_return(json({ "state" => "active" }))
    # Create hands back a box still starting; start requests are accepted.
    stub_request(:post, "#{API}/sandbox").to_return(json({ "id" => BOX, "state" => "starting" }))
    stub_request(:post, "#{API}/sandbox/#{BOX}/start").to_return(json({}))
    # First confirm 404s (vanished → raises); the retry's confirm finds it started.
    stub_request(:get, "#{API}/sandbox/#{BOX}")
      .to_return({ status: 404 }, json({ "id" => BOX, "state" => "started" }))
    stub_exec

    assert_equal "ok\n", build.exec("echo ok").stdout # resolves the box (find_or_create) then runs — no raise
    assert_requested :post, "#{API}/sandbox", times: 2  # created a fresh box on the retry
  end

  def test_config_fails_fast_without_api_key
    assert_raises(Rbrun::Sandbox::Error) do
      Rbrun::Sandbox::Daytona.new(config: { api_url: API }, labels: {})
    end
  end

  def test_exec_normalizes_to_exec_result
    stub_exec
    result = build.exec("echo ok")
    assert_instance_of Rbrun::Sandbox::ExecResult, result
    assert result.success?
    assert_equal "ok\n", result.stdout
  end

  def test_exec_sends_the_command_to_the_box
    stub_exec
    build.exec("echo ok", timeout: 30)
    assert_requested(:post, "#{TOOLBOX}/#{BOX}/process/execute") do |req|
      JSON.parse(req.body) == { "command" => "echo ok", "timeout" => 30 }
    end
  end

  def test_exec_bang_raises_on_nonzero
    stub_exec(exit_code: 2, result: "nope")
    assert_raises(Rbrun::Sandbox::Error) { build.exec!("boom") }
  end

  def test_exist_is_true_on_exit_zero
    stub_exec(exit_code: 0, result: "")
    assert build.exist?("/some/path")
  end

  def test_exist_is_false_on_nonzero_exit
    stub_exec(exit_code: 1, result: "")
    refute build.exist?("/missing/path")
  end

  def test_read_downloads_the_path
    stub_request(:get, "#{TOOLBOX}/#{BOX}/files/download")
      .with(query: { "path" => "/w/a.txt" })
      .to_return(status: 200, body: "contents")
    assert_equal "contents", build.read("/w/a.txt")
  end

  def test_write_creates_folder_then_uploads
    folder = stub_request(:post, "#{TOOLBOX}/#{BOX}/files/folder")
      .with(query: { "path" => "/w/dir", "mode" => "755" }).to_return(status: 200, body: "")
    stub_request(:post, "#{TOOLBOX}/#{BOX}/files/upload")
      .with(query: { "path" => "/w/dir/a.txt" }).to_return(status: 200, body: "")

    build.write("/w/dir/a.txt", "hello")

    assert_requested folder
    # the content lands in the multipart body, not just the path query
    assert_requested(:post, "#{TOOLBOX}/#{BOX}/files/upload?path=/w/dir/a.txt") { |req| req.body.include?("hello") }
  end

  def test_session_delegates_with_box_id
    session = "#{TOOLBOX}/#{BOX}/process/session"
    stub_request(:post, session).to_return(json({}))
    stub_request(:post, "#{session}/s1/exec").to_return(json({ "cmdId" => "cmd-9" }))
    stub_request(:post, "#{session}/s1/command/cmd-9/input").to_return(json({}))
    stub_request(:get, "#{session}/s1/command/cmd-9").to_return(json({ "exitCode" => 0 }))

    adapter = build
    adapter.session_create("s1")
    assert_equal "cmd-9", adapter.session_exec("s1", "run")
    adapter.session_input("s1", "cmd-9", "data")
    assert_equal 0, adapter.session_command("s1", "cmd-9")["exitCode"]

    assert_requested(:post, session) { |req| JSON.parse(req.body) == { "sessionId" => "s1" } }
    assert_requested(:post, "#{session}/s1/exec") { |req| JSON.parse(req.body)["command"] == "run" }
    assert_requested(:post, "#{session}/s1/command/cmd-9/input") { |req| JSON.parse(req.body) == { "data" => "data" } }
  end

  # A session that already exists is success for a caller that only wants it to exist — the box is
  # found by label, so a relaunch under a deterministic session name always meets its own 409.
  def test_session_create_is_idempotent_on_409
    stub_request(:post, "#{TOOLBOX}/#{BOX}/process/session")
      .to_return(json({ "message" => "session already exists" }, status: 409))
    assert_nil build.session_create("s1")
  end

  def test_session_create_raises_on_other_errors
    stub_request(:post, "#{TOOLBOX}/#{BOX}/process/session")
      .to_return(json({ "message" => "boom" }, status: 500))
    assert_raises(Rbrun::Sandbox::Error) { build.session_create("s1") }
  end

  def test_destroy_resets_the_box
    destroy = stub_request(:delete, "#{API}/sandbox/#{BOX}")
      .with(query: { "force" => "true" }).to_return(status: 200, body: "")
    build.destroy!
    assert_requested destroy
  end
end
