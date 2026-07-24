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

    # Registry creds are needed to DEPLOY (kamal pushes an image), not to provision — so the capability
    # is gated at deploy. Blank creds used to be shipped to kamal, which failed at docker login with a
    # wall of output that never says "you didn't configure a registry".
    test "hetzner: deploy refuses without registry credentials, naming what is missing" do
      client = Rbrun::Server::KamalHetzner.new(config: { hcloud_token: "tok" })
      error = assert_raises(Rbrun::Server::Error) do
        client.deploy(work_dir: "/tmp", host: "w.rb.run", server_ip: "1.2.3.4", ssh_private_key: "k")
      end
      assert_match(/registry/, error.message)
      assert_match(/server|username|password/, error.message)
    end

    # The cmd-id probe chain had no terminus: all three key names absent yielded nil, and nil was
    # returned as a good command id. Every later call then built ".../command//logs" and 404'd, so the
    # error read like a transport/permissions problem instead of an unrecognised exec response.
    test "daytona: an exec response with no recognisable command id raises here, not as a 404 later" do
      conn = Faraday.new do |f|
        f.adapter :test do |stub|
          stub.post(/exec/) { [ 200, { "Content-Type" => "application/json" }, { "unexpected" => "shape" } ] }
        end
      end
      client = Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "https://example.test")
      client.instance_variable_set(:@conn, conn)
      error = assert_raises(Rbrun::Sandbox::Daytona::Client::Error) do
        client.send(:session_exec, "box", "sess", "echo hi")
      end
      assert_match(/no command id/, error.message)
    end
  end
end
