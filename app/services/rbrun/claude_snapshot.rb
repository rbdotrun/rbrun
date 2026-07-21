require "shellwords"

module Rbrun
  # Engine-owned turn idempotency: snapshot the WHOLE SDK config dir (<workspace>/.claude — resume history,
  # settings, todos, everything) to the engine's own DB after every turn, and restore it onto a fresh box
  # when the box was lost — so a turn does not depend on a specific live box (invariant #11). Snapshotting
  # the whole dir means we never have to know WHERE the SDK keeps resume state: whatever it wrote comes back.
  # Drives the sandbox's exec/read/write primitives only; the pure sandbox gem stays snapshot-agnostic.
  class ClaudeSnapshot
    # The transfer tar lives INSIDE the workspace (an absolute path both backends resolve identically —
    # Local only passes through paths under its root), and is removed right after use so it is never
    # committed. A dotfile so it stays out of the way if a crash ever leaves it.
    TAR_NAME = ".rbrun-claude-snapshot.tgz"

    def initialize(session)
      @session = session
    end

    # After a turn: tar .claude (minus excludes) and upsert it, keyed by session. BEST-EFFORT — a snapshot
    # that fails is logged, never raised: the answer already streamed, and a lost snapshot only costs the
    # NEXT box-loss its most-recent turn, never the turn in flight.
    def capture!
      sandbox = @session.sandbox
      dir = claude_dir(sandbox)
      return unless sandbox.exist?(dir)

      tar = tar_path(sandbox)
      sandbox.exec!("tar czf #{esc(tar)} -C #{esc(dir)} .")
      bytes = sandbox.read(tar)
      sandbox.exec("rm -f #{esc(tar)}")
      snapshot = Rbrun::SessionSnapshot.find_or_initialize_by(session: @session)
      snapshot.update!(data: bytes)
      snapshot
    rescue StandardError => e
      Rails.logger.warn("[rbrun] claude snapshot failed (session=#{@session.id}): #{e.class}: #{e.message}")
      nil
    end

    # Before a turn: if we hold a snapshot AND the box has no .claude at all (fresh/lost box), write it back
    # so the SDK can resume. Restore runs BEFORE the runtime stages skills, so a box that still carries its
    # .claude is a LIVE box → NO-OP (restoring an older snapshot over newer history would corrupt the
    # conversation — the presence guard is load-bearing). Best-effort.
    def restore_if_lost!
      snapshot = @session.snapshot
      return false if snapshot.nil? || snapshot.data.blank?

      sandbox = @session.sandbox
      dir = claude_dir(sandbox)
      return false if sandbox.exist?(dir)

      tar = tar_path(sandbox)
      sandbox.write(tar, snapshot.data)
      sandbox.exec!("mkdir -p #{esc(dir)} && tar xzf #{esc(tar)} -C #{esc(dir)}")
      sandbox.exec("rm -f #{esc(tar)}")
      true
    rescue StandardError => e
      Rails.logger.warn("[rbrun] claude restore failed (session=#{@session.id}): #{e.class}: #{e.message}")
      false
    end

    private

    def claude_dir(sandbox) = File.join(sandbox.workspace, ".claude")
    def tar_path(sandbox)   = File.join(sandbox.workspace, TAR_NAME)

    def esc(str) = Shellwords.escape(str)
  end
end
