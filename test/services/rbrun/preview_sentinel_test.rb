require "test_helper"

module Rbrun
  class PreviewSentinelTest < ActiveSupport::TestCase
    # A DNS double at the Rbrun.dns seam: it reports whatever records "exist" at the edge and records the
    # reconciling calls the sentinel makes. Not a fake HTTP client — the real Cloudflare paging/filtering is
    # covered by the gem's WebMock suite.
    class FakeDns
      attr_reader :removed, :created

      def initialize(existing) = (@existing = existing; @removed = []; @created = [])
      def list(type: nil, name_suffix: nil) = @existing
      def remove(name:, type: nil) = (@removed << name) && true
      def upsert(name:, type:, content:, proxied: false)
        @created << name
        Rbrun::Dns::Record.new(id: "new", name: name, type: type, content: content, proxied: proxied)
      end
    end

    def rec(name) = Rbrun::Dns::Record.new(id: name, name: name, type: "CNAME", content: "t.cfargotunnel.com", proxied: true)

    def expose(token:, previewed:, tenant: "acme")
      wt = rbrun_worktree(tenant: tenant, repo: "#{tenant}/app")
      wt.service_exposures.create!(name: "web", preview_token: token, previewed: previewed)
    end

    setup do
      @domain = Rbrun.config.preview_domain
      @target = Rbrun.config.preview_target
      @edge   = Rbrun.preview_edge
      Rbrun.config.preview_domain = "rb.run"
      Rbrun.config.preview_target = "t.cfargotunnel.com"
    end

    teardown do
      Rbrun.config.preview_domain = @domain
      Rbrun.config.preview_target = @target
      Rbrun.preview_edge = @edge
    end

    test "reaps orphan records and restores missing ones, leaving matched ones alone — across tenants" do
      expose(token: "keepme",  previewed: true,  tenant: "acme") # present at edge → untouched
      expose(token: "restore", previewed: true,  tenant: "globex") # no record → recreated
      expose(token: "notme",   previewed: false, tenant: "acme") # not previewed → not desired

      dns = FakeDns.new([ rec("keepme-preview.rb.run"), rec("stale-preview.rb.run") ])
      summary = Rbrun::PreviewSentinel.reconcile!(dns: dns)

      assert_equal [ "stale-preview.rb.run" ], dns.removed
      assert_equal [ "restore-preview.rb.run" ], dns.created
      assert_equal [ "stale-preview.rb.run" ], summary[:removed]
      assert_equal [ "restore-preview.rb.run" ], summary[:created]
    end

    test "no-ops entirely when the host owns the edge" do
      expose(token: "x", previewed: true)
      Rbrun.preview_edge = Object.new
      dns = FakeDns.new([ rec("stale-preview.rb.run") ])

      summary = Rbrun::PreviewSentinel.reconcile!(dns: dns)
      assert summary[:skipped]
      assert_empty dns.removed
      assert_empty dns.created
    end

    test "no-ops when DNS is unconfigured" do
      Rbrun.config.preview_target = nil
      dns = FakeDns.new([ rec("stale-preview.rb.run") ])

      summary = Rbrun::PreviewSentinel.reconcile!(dns: dns)
      assert summary[:skipped]
      assert_empty dns.removed
    end
  end
end
