require "test_helper"

module Rbrun
  class SessionRunTurnTest < ActiveSupport::TestCase
    class OkRuntime
      def run(**) = { type: "result", stop_reason: "end_turn" }
    end

    class GateRuntime
      def run(on_event:, **)
        on_event.call({ type: "needs_approval", tool: "x", arguments: {}, tool_use_id: "g", tool_kind: "ruby" })
        { type: "result", stop_reason: "awaiting_approval" }
      end
    end

    class BoomRuntime
      def run(**) = raise("kaboom")
    end

    setup { @s = rbrun_session(tenant: "acme") }

    test "a clean turn ends done" do
      @s.run_turn("hi", runtime: OkRuntime.new)
      assert @s.done?
    end

    test "a gated turn parks on needs_approval" do
      @s.run_turn("dangerous", runtime: GateRuntime.new)
      assert @s.needs_approval?
      assert_equal 1, @s.messages.gated.count
    end

    test "a failing turn flips to failed, logs an error row, and re-raises" do
      assert_raises(RuntimeError) { @s.run_turn("break", runtime: BoomRuntime.new) }
      assert @s.failed?
      assert @s.messages.exists?(event_type: "error")
    end
  end
end
