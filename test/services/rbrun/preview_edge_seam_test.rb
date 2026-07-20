require "test_helper"

module Rbrun
  # The bypass seam: when the HOST owns the preview edge (Rbrun.preview_edge), the engine creates NO DNS
  # and serves NO proxy — it asks the host to expose/revoke and stores the returned URL.
  class PreviewEdgeSeamTest < ActiveSupport::TestCase
    # A recording host edge (the control plane's role).
    class HostEdge
      attr_reader :exposed, :revoked
      def initialize = (@exposed = []; @revoked = [])
      def expose(run) = (@exposed << run.name) && "https://web.customer.example"
      def revoke(run) = (@revoked << run.name)
    end

    setup do
      @edge = HostEdge.new
      Rbrun.preview_edge = @edge
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @launcher = Rbrun::ServiceLauncher.new(worktree: @worktree)
      @launcher.start([ { "name" => "web", "command" => "sh -c 'sleep 30'", "port" => 4321 } ])
    end

    teardown do
      Rbrun.preview_edge = nil
      @worktree.sandbox.destroy!
    end

    test "preview asks the host to expose and stores its URL — no token, no upstream" do
      exp = @launcher.preview("web")
      assert_equal [ "web" ], @edge.exposed
      assert_equal "https://web.customer.example", exp.preview_url
      assert_nil exp.preview_token, "the engine mints no token when the host owns the edge"
      assert_nil @worktree.service_runs.find_by(name: "web").url, "no provider upstream resolved"
    end

    test "stop_preview asks the host to revoke and clears the stored URL" do
      @launcher.preview("web")
      @launcher.stop_preview("web")
      assert_equal [ "web" ], @edge.revoked
      assert_nil @launcher.exposure("web").preview_url
    end

    test "PreviewDomain.expose! no-ops while the host owns the edge" do
      calls = []
      dns = Object.new.tap { |o| o.define_singleton_method(:upsert) { |**kw| calls << kw } }
      Rbrun.config.preview_domain = "rb.run"
      Rbrun.config.preview_target = "t.cfargotunnel.com"
      Rbrun::PreviewDomain.expose!("abc", dns: dns)
      assert_empty calls
    ensure
      Rbrun.config.preview_domain = nil
      Rbrun.config.preview_target = nil
    end
  end
end
