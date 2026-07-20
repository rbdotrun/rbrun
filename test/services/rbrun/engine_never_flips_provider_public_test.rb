require "test_helper"

module Rbrun
  # Invariant #10: the engine serves level 3 through its OWN edge and NEVER flips the provider's box-wide
  # public switch (the box stays private). This guards against set_public creeping back into a launcher.
  class EngineNeverFlipsProviderPublicTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "rbrun", repo: "a/b")
      @launcher = Rbrun::ServiceLauncher.new(worktree: @worktree)
    end

    teardown { @worktree.sandbox.destroy! }

    test "share_public / stop_sharing never call sandbox.set_public" do
      @launcher.start([ { "name" => "web", "command" => "sh -c 'sleep 30'", "port" => 4321 } ])
      @launcher.preview("web")

      # If anything called it, this raises — set_public exists on the (Local) sandbox, so we can trap it.
      @worktree.sandbox.define_singleton_method(:set_public) { |*| raise "the engine flipped the provider public switch!" }

      assert_nothing_raised do
        @launcher.share_public("web")
        @launcher.stop_sharing("web")
      end
      assert @launcher.shared?("web") == false, "revoked cleanly through the engine's own model"
    end
  end
end
