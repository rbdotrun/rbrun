require "test_helper"
require "json"

class ClaudeSdkLoopTest < Minitest::Test
  SCRIPT = File.expand_path("../../support/protocol_script.rb", __dir__)

  def setup
    @sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "loop-#{Process.pid}" })
    @runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: @sandbox, config: { anthropic_api_key: "k" })
  end

  def teardown
    @sandbox&.destroy!
  end

  def test_run_over_session_drives_events_and_the_tool_bridge
    events = []
    tool_calls = []
    handler = ->(event) do
      tool_calls << event
      { result: { sum: event[:args][:a] + event[:args][:b] }, is_error: false }
    end

    result = @runtime.send(
      :run_over_session,
      "ruby #{SCRIPT}",              # the "client" command — a real local process
      tool_handler: handler,
      on_event: ->(e) { events << e }
    )

    # tool bridge round-tripped
    assert_equal 1, tool_calls.size
    assert_equal "add", tool_calls.first[:name]
    # non-terminal, non-tool events reached on_event
    assert(events.any? { |e| e[:type] == "session" })
    assert(events.any? { |e| e[:type] == "assistant" && e[:text] == "working" })
    # terminal result returned, structured_output string-keyed and carrying our tool result
    assert_equal "success", result[:subtype]
    assert_equal({ "echoed" => { "sum" => 5 } }, result[:structured_output])
  end
end
