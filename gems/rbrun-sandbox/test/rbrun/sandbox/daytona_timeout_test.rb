require "test_helper"
require "async"

class DaytonaTimeoutTest < Minitest::Test
  class TimingOutClient
    def find_or_create(_labels) = { "id" => "box", "state" => "started" }
    def session_logs_follow(_id, _sid, _cid, skip: 0, timeout: nil)
      raise Async::TimeoutError, "boom"
    end
  end

  def test_follow_timeout_surfaces_as_sandbox_timeout_error
    adapter = Rbrun::Sandbox::Daytona.new(config: { api_key: "k", api_url: "u" },
                                          labels: { s: 1 }, client: TimingOutClient.new)
    assert_raises(Rbrun::Sandbox::TimeoutError) do
      adapter.session_logs_follow("s", "c", timeout: 1) { |_| false }
    end
  end
end
