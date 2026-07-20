require "test_helper"
require "socket"

module Rbrun
  # The hijacked WebSocket relay, driven with a REAL loopback upstream (a tiny TCPServer speaking the
  # handshake then echoing) — no fake objects.
  class PreviewSocketTest < ActiveSupport::TestCase
    # An upstream that completes the WS handshake, then echoes each chunk UPPERCASED so we can prove the
    # bytes went there and came back.
    def with_echo_upstream
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      thread = Thread.new do
        conn = server.accept
        conn.readpartial(4096) # the handshake request
        conn.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        conn.flush
        while (chunk = (conn.readpartial(4096) rescue nil))
          break if chunk.nil? || chunk.empty?
          conn.write(chunk.upcase); conn.flush
        end
      rescue StandardError
      ensure
        conn&.close
      end
      yield port
    ensure
      thread&.kill
      server&.close
    end

    test "bridge relays the 101 and pumps bytes bidirectionally" do
      with_echo_upstream do |port|
        browser, hijacked = UNIXSocket.pair # `hijacked` is handed to the bridge as the browser socket

        bridge = Thread.new do
          Rbrun::PreviewSocket.bridge(hijacked, url: "ws://127.0.0.1:#{port}/live", headers: { "x-daytona-preview-token" => "tok" })
        end

        # the upstream 101 is relayed back to the browser end
        handshake = browser.readpartial(1024)
        assert_includes handshake, "101 Switching Protocols"

        # a frame's bytes reach upstream and the (uppercased) echo returns — proving both directions
        browser.write("ping"); browser.flush
        assert_equal "PING", browser.readpartial(64)

        browser.close
        bridge.join(2)
      end
    end

    test "the cap refuses the upgrade past preview_max_sockets, without hijacking" do
      prev = Rbrun.config.preview_max_sockets
      Rbrun.config.preview_max_sockets = 1
      Rbrun::PreviewProxy.sockets = 1 # already at the cap

      hijacked = false
      env = { "rack.hijack" => -> { hijacked = true } }
      request = ActionDispatch::Request.new(env.merge("HTTP_UPGRADE" => "websocket"))
      run = Struct.new(:url).new("https://box/")

      status, = Rbrun::PreviewProxy.new(->(_) { }).send(:upgrade, request, run)
      assert_equal 503, status
      refute hijacked, "must not hijack the socket when over the cap"
    ensure
      Rbrun::PreviewProxy.sockets = 0
      Rbrun.config.preview_max_sockets = prev
    end
  end
end
