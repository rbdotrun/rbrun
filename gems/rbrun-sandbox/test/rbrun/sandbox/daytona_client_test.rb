require "test_helper"

class DaytonaClientTest < Minitest::Test
  def test_missing_api_key_fails_fast
    error = assert_raises(Rbrun::Sandbox::Daytona::Client::Error) do
      Rbrun::Sandbox::Daytona::Client.new(api_key: "", api_url: "https://api.example")
    end
    assert_match(/credentials missing/i, error.message)
  end

  def test_builds_an_async_http_faraday_connection
    client = Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "https://api.example")
    conn = client.send(:conn)
    assert_equal Async::HTTP::Faraday::Adapter, conn.builder.adapter.klass
    assert_equal "Bearer k", conn.headers["Authorization"]
  end

  def test_snapshot_ref_is_content_addressed_by_the_dockerfile
    default_client = Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "u")
    custom_client  = Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "u",
                                                         dockerfile: "FROM alpine\n", snapshot_name: "mine")
    # a host-injected Dockerfile changes the snapshot tag; same input ⇒ same tag (reuse).
    assert_match(%r{\Arbrun-sandbox:[0-9a-f]{16}\z}, default_client.snapshot_ref)
    assert_match(%r{\Amine:[0-9a-f]{16}\z}, custom_client.snapshot_ref)
    refute_equal default_client.snapshot_ref, custom_client.snapshot_ref
    assert_equal custom_client.snapshot_ref,
                 Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "u",
                                                     dockerfile: "FROM alpine\n", snapshot_name: "mine").snapshot_ref
  end
end
