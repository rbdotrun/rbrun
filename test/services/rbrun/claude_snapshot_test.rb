require "test_helper"

module Rbrun
  # Exercises the real backup/restore against the Local sandbox (the dummy's default backend) — no stubs.
  class ClaudeSnapshotTest < ActiveSupport::TestCase
    setup do
      @worktree = Rbrun::Worktree.create!(tenant: "acme", repo: "acme/app")
      @session  = @worktree.sessions.create!
      @sandbox  = @session.sandbox
      # A box mid-conversation: SDK resume history under projects/, settings, and a re-staged skill.
      @sandbox.write(".claude/projects/sess.jsonl", %({"type":"summary"}\n))
      @sandbox.write(".claude/settings.json", "{}")
      @sandbox.write(".claude/skills/pdf/SKILL.md", "# staged fresh each turn")
    end

    teardown { @sandbox.destroy! }

    def claude(path) = File.join(@sandbox.workspace, ".claude", path)
    def wipe_claude! = @sandbox.exec!("rm -rf .claude") # Local execs in the workspace

    test "capture! stores the .claude history as one upserted row" do
      assert_difference("Rbrun::SessionSnapshot.count", 1) do
        Rbrun::ClaudeSnapshot.new(@session).capture!
      end
      assert @session.reload.snapshot.data.present?

      assert_no_difference("Rbrun::SessionSnapshot.count") do
        Rbrun::ClaudeSnapshot.new(@session).capture! # upsert, never a second row
      end
    end

    test "capture! leaves no transfer tar behind in the workspace" do
      Rbrun::ClaudeSnapshot.new(@session).capture!
      assert_not @sandbox.exist?(File.join(@sandbox.workspace, Rbrun::ClaudeSnapshot::TAR_NAME))
    end

    test "restore_if_lost! rebuilds the WHOLE .claude on a fresh box" do
      Rbrun::ClaudeSnapshot.new(@session).capture!
      wipe_claude!
      assert_not @sandbox.exist?(claude("projects/sess.jsonl"))

      assert Rbrun::ClaudeSnapshot.new(@session).restore_if_lost!
      assert_equal %({"type":"summary"}\n), @sandbox.read(claude("projects/sess.jsonl")), "resume history"
      assert @sandbox.exist?(claude("settings.json")), "settings restored"
      # The whole dir comes back — we never have to know where the SDK keeps resume state.
      assert @sandbox.exist?(claude("skills/pdf/SKILL.md")), "whole .claude restored"
    end

    test "restore_if_lost! is a NO-OP on a live box (never clobbers newer history)" do
      Rbrun::ClaudeSnapshot.new(@session).capture!
      @sandbox.write(".claude/projects/sess.jsonl", %({"type":"newer"}\n)) # box moved on since the snapshot

      assert_not Rbrun::ClaudeSnapshot.new(@session).restore_if_lost!
      assert_equal %({"type":"newer"}\n), @sandbox.read(claude("projects/sess.jsonl")), "not clobbered"
    end

    test "restore_if_lost! is a no-op with no snapshot" do
      wipe_claude!
      assert_not Rbrun::ClaudeSnapshot.new(@session).restore_if_lost!
    end

    test "capture! no-ops when the box has no .claude yet" do
      wipe_claude!
      assert_nil Rbrun::ClaudeSnapshot.new(@session).capture!
      assert_nil @session.reload.snapshot
    end
  end
end
