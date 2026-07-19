require "test_helper"

class LocalSessionTest < Minitest::Test
  def setup
    @sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "sess-#{Process.pid}" })
  end

  def teardown
    @sandbox&.destroy!
  end

  def test_session_streams_stdin_to_stdout_and_reports_exit
    @sandbox.session_create("s1")
    # `cat` echoes stdin to stdout, then exits when stdin closes.
    cmd_id = @sandbox.session_exec("s1", "cat")

    @sandbox.session_input("s1", cmd_id, "ping\n")

    seen = String.new
    bytes = @sandbox.session_logs_follow("s1", cmd_id, skip: 0, timeout: 5) do |chunk|
      seen << chunk
      seen.include?("ping") # stop following once we've observed the echo
    end

    assert_includes seen, "ping"
    assert bytes.positive?
  end

  def test_session_command_reports_exit_code_after_completion
    @sandbox.session_create("s2")
    cmd_id = @sandbox.session_exec("s2", "exit 0")
    # drain to completion
    @sandbox.session_logs_follow("s2", cmd_id, timeout: 5) { |_| false }
    assert_equal 0, @sandbox.session_command("s2", cmd_id)["exitCode"]
  end

  def test_logs_follow_skip_resumes_without_replay
    @sandbox.session_create("s3")
    # Emit over time (AAAAA, pause, BBBBB) so the first follow consumes only the A's, like a real
    # incrementally-producing process (bun client.ts). A fast one-shot printf would write all bytes
    # before the first read, defeating a partial-consumption test.
    cmd_id = @sandbox.session_exec("s3", "printf AAAAA; sleep 0.3; printf BBBBB")
    first = String.new
    offset = @sandbox.session_logs_follow("s3", cmd_id, skip: 0, timeout: 5) do |c|
      first << c
      first.include?("AAAAA") # stop once the first burst is seen, before the B's arrive
    end
    # resume from the offset already consumed — must not replay the A's
    rest = String.new
    @sandbox.session_logs_follow("s3", cmd_id, skip: offset, timeout: 5) { |c| rest << c; false }
    refute_includes rest, "AAAAA"
    assert_includes rest, "BBBBB"
  end
end
