require "test_helper"

module Rbrun
  class PublicSharingToolsTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @session  = @worktree.sessions.create!
      @launcher = Rbrun::ServiceLauncher.new(worktree: @worktree)
    end

    teardown { @worktree.sandbox.destroy! }

    def tool(klass) = klass.in_session(@session)

    def start_web!
      @launcher.start([ { "name" => "web", "command" => "sh -c 'sleep 30'", "port" => 4331 } ])
    end

    test "share_public is GATED; stop_sharing is not" do
      assert Rbrun::Tools::SharePublic.needs_approval?, "public exposure must be a human decision"
      refute Rbrun::Tools::StopSharing.needs_approval?, "revoking is always safe"

      manifest = Rbrun::ApplicationTool.manifest.index_by { |e| e["name"] }
      assert manifest["share_public"]["needs_approval"]
      refute manifest["stop_sharing"]["needs_approval"]
    end

    test "share_public refuses a service that is not previewed (public requires preview)" do
      start_web!
      res = tool(Rbrun::Tools::SharePublic).execute(name: "web")
      assert_includes res["error"], "not previewed"
      refute @launcher.shared?("web")
    end

    test "previewed → share_public returns a public url; stop_sharing revokes it" do
      start_web!
      @launcher.preview("web")

      res = tool(Rbrun::Tools::SharePublic).execute(name: "web")
      assert res.dig("data", "public")
      assert_match %r{^http}, res.dig("data", "url")
      assert @launcher.shared?("web")

      off = tool(Rbrun::Tools::StopSharing).execute(name: "web")
      refute off.dig("data", "public")
      refute @launcher.shared?("web")
    end

    test "share_public errors on an unknown service" do
      assert_includes tool(Rbrun::Tools::SharePublic).execute(name: "nope")["error"], "no such service"
    end
  end
end
