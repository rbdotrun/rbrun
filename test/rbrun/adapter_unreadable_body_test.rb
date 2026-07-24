require "test_helper"
require "faraday"

module Rbrun
  # "I couldn't read the answer" must never become "it doesn't exist".
  #
  # Both adapters normalize their HTTP body and used to `rescue {}` — including on a 2xx. An empty hash
  # then flowed on as a perfectly good success: `find_server`/`find` did `Array(nil).first` → nil, the
  # find-or-create guard missed, and the caller CREATED A DUPLICATE — a second billable Hetzner box, or
  # a duplicate DNS record. Both adapters' docstrings promise idempotency (invariant #11); this is the
  # hole. Unreadable success now raises.
  class AdapterUnreadableBodyTest < ActiveSupport::TestCase
    # A Faraday connection whose 200 body is NOT JSON (a proxy/HTML error page, a truncated response).
    def conn_returning(status:, body:)
      Faraday.new do |f|
        f.adapter :test do |stub|
          stub.get(/.*/)  { [ status, { "Content-Type" => "text/html" }, body ] }
          stub.post(/.*/) { [ status, { "Content-Type" => "text/html" }, body ] }
        end
      end
    end

    test "hetzner: an unreadable 200 raises instead of reporting 'no such server'" do
      client = Rbrun::Server::KamalHetzner.new(
        config: { hcloud_token: "tok" }, conn: conn_returning(status: 200, body: "<html>gateway</html>")
      )
      error = assert_raises(Rbrun::Server::Error) { client.find_server(name: "rbrun-w1") }
      assert_match(/unparseable 200/, error.message)
    end

    test "cloudflare: an unreadable 200 raises instead of reporting 'no such record'" do
      client = Rbrun::Dns::Cloudflare.new(
        config: { api_token: "tok", zone_id: "z" }, conn: conn_returning(status: 200, body: "not json")
      )
      error = assert_raises(Rbrun::Dns::Error) { client.find(name: "w.rb.run") }
      assert_match(/unparseable 200/, error.message)
    end

    test "a readable error body still reports the API's own message (not the parse failure)" do
      client = Rbrun::Dns::Cloudflare.new(
        config: { api_token: "tok", zone_id: "z" },
        conn: conn_returning(status: 403, body: '{"errors":[{"message":"bad token"}]}')
      )
      error = assert_raises(Rbrun::Dns::Error) { client.find(name: "w.rb.run") }
      assert_match(/bad token/, error.message)
    end

    test "an unreadable ERROR body still raises with the status (parse failure is not masked)" do
      client = Rbrun::Server::KamalHetzner.new(
        config: { hcloud_token: "tok" }, conn: conn_returning(status: 502, body: "<html>bad gateway</html>")
      )
      error = assert_raises(Rbrun::Server::Error) { client.find_server(name: "x") }
      assert_match(/502/, error.message)
    end
  end
end
