require "test_helper"

module Rbrun
  class PreviewDomainTest < ActiveSupport::TestCase
    # A DNS double at the ENGINE seam (Rbrun.dns injection point) — not a fake HTTP client. Records the
    # one call the engine makes.
    class RecordingDns
      attr_reader :calls
      def initialize = @calls = []
      def upsert(**kw) = (@calls << kw) && Rbrun::Dns::Record.new(id: "r1", **kw)
    end

    setup do
      @domain = Rbrun.config.preview_domain
      @target = Rbrun.config.preview_target
      @edge   = Rbrun.preview_edge
    end

    teardown do
      Rbrun.config.preview_domain = @domain
      Rbrun.config.preview_target = @target
      Rbrun.preview_edge = @edge
    end

    test "host_for builds a single-label host, token_from_host reverses it" do
      Rbrun.config.preview_domain = "rb.run"
      assert_equal "abc-preview.rb.run", Rbrun::PreviewDomain.host_for("abc")
      assert_equal "abc", Rbrun::PreviewDomain.token_from_host("abc-preview.rb.run")
      assert_equal "abc", Rbrun::PreviewDomain.token_from_host("abc-preview.rb.run:443")
      assert_nil Rbrun::PreviewDomain.token_from_host("something-else.rb.run")
      assert_nil Rbrun::PreviewDomain.token_from_host("app.example.com")
    end

    test "ensure! no-ops when previews are unconfigured" do
      Rbrun.config.preview_domain = nil
      dns = RecordingDns.new
      Rbrun::PreviewDomain.ensure!(dns: dns)
      assert_empty dns.calls
    end

    test "ensure! upserts exactly ONE wildcard CNAME when configured" do
      Rbrun.config.preview_domain = "rb.run"
      Rbrun.config.preview_target = "tid.cfargotunnel.com"
      dns = RecordingDns.new
      Rbrun::PreviewDomain.ensure!(dns: dns)

      assert_equal 1, dns.calls.size
      call = dns.calls.first
      assert_equal "*.rb.run", call[:name]
      assert_equal "CNAME", call[:type]
      assert_equal "tid.cfargotunnel.com", call[:content]
      assert call[:proxied]
    end

    test "ensure! no-ops when the host owns the edge (preview_edge set)" do
      Rbrun.config.preview_domain = "rb.run"
      Rbrun.config.preview_target = "tid.cfargotunnel.com"
      Rbrun.preview_edge = Object.new # host owns the data path
      dns = RecordingDns.new
      Rbrun::PreviewDomain.ensure!(dns: dns)
      assert_empty dns.calls
    end
  end
end
