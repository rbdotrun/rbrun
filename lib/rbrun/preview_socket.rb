# frozen_string_literal: true

require "socket"
require "openssl"
require "uri"

module Rbrun
  # A hijacked WebSocket relay between the browser and a service inside the sandbox. Verified identical on
  # Puma 8 and Falcon 0.55 (same rack.hijack contract). We PUMP BYTES, never parse frames — so
  # subprotocols, permessage-deflate, pings and binary frames all pass untouched.
  #
  # A concurrency CAP is enforced by the caller BEFORE hijacking: on Puma each live socket pins a thread,
  # so uncapped upgrades would starve the app. On Falcon a connection is a fiber and the cap can be lifted.
  class PreviewSocket
    UPGRADE = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"

    # Bridge `client` (the hijacked browser socket) to the upstream websocket at `url`, sending the
    # handshake with `headers` (which carry the provider token). Blocks until either side closes.
    def self.bridge(client, url:, headers:)
      new(client, url, headers).run
    end

    def initialize(client, url, headers)
      @client  = client
      @uri     = URI(url)
      @headers = headers
    end

    def run
      upstream = connect_upstream
      pump(@client, upstream)
      pump(upstream, @client)
      @threads.each(&:join)
    ensure
      close(@client)
      close(@upstream)
    end

    private

    # Open a TCP (+TLS for wss/https upstream) socket and send the upgrade handshake to the sandbox.
    def connect_upstream
      tcp = TCPSocket.new(@uri.host, @uri.port || (tls? ? 443 : 80))
      @upstream = tls? ? tls_socket(tcp) : tcp

      path = @uri.path.to_s.empty? ? "/" : @uri.path
      path = "#{path}?#{@uri.query}" if @uri.query
      request = +"GET #{path} HTTP/1.1\r\n"
      request << "Host: #{@uri.host}\r\n"
      request << "Upgrade: websocket\r\nConnection: Upgrade\r\n"
      @headers.each { |k, v| request << "#{k}: #{v}\r\n" }
      request << "\r\n"
      @upstream.write(request)
      @upstream.flush

      relay_upstream_handshake
      @upstream
    end

    # Read the upstream 101 response headers and forward them verbatim to the browser (completing its
    # handshake), then hand off to the byte pump for the frames that follow.
    def relay_upstream_handshake
      header = read_until_headers_end(@upstream)
      @client.write(header)
      @client.flush
    end

    def pump(from, to)
      @threads ||= []
      @threads << Thread.new do
        while (chunk = safe_read(from))
          to.write(chunk)
          to.flush
        end
      rescue StandardError
        # a closed/reset peer ends the bridge
      ensure
        close(to) # half-close cascades: when one direction ends, tear the other down
      end
    end

    def safe_read(io)
      io.readpartial(16_384)
    rescue EOFError, IOError, Errno::ECONNRESET
      nil
    end

    def read_until_headers_end(io)
      buffer = +""
      buffer << io.readpartial(1) until buffer.end_with?("\r\n\r\n") || buffer.bytesize > 8_192
      buffer
    end

    def tls? = %w[https wss].include?(@uri.scheme)

    def tls_socket(tcp)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new.tap { |c| c.verify_mode = OpenSSL::SSL::VERIFY_PEER })
      ssl.hostname = @uri.host # SNI
      ssl.connect
      ssl
    end

    def close(io)
      io&.close
    rescue StandardError
      nil
    end
  end
end
