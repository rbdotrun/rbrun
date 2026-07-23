module Rbrun
  # ONE turn: builds the runtime in the session's sandbox, streams its events into the session's
  # event log, and services tool calls in Ruby. Everything the run emits is ingested verbatim; a
  # gated call freezes a durable row and ends the turn.
  class AgentTurn
    attr_reader :gated
    alias gated? gated

    # `runtime:` is an injection seam (tests pass a scripted fake); nil ⇒ the real config-resolved
    # runtime in the session's sandbox.
    def initialize(session:, runtime: nil)
      @session = session
      @runtime = runtime
      @gated = false
    end

    def run(content)
      @session.messages.create!(role: "user", event_type: "text", content:)
      call_client(content)
    end

    # Continue after an approval decision — the tool already ran. NOT a user message; log an app-voice
    # `internal` row and hand the nudge straight to the SDK.
    def continue(nudge)
      internal("Decision recorded — resuming.", "approval")
      call_client(nudge)
    end

    # Resume a failed turn — the SDK session carries the partial state; restate the request.
    def resume
      internal("Resuming at your request.", "resume")
      call_client(resume_prompt)
    end

    private

      # The host system prompt, plus a per-session steer toward this conversation's `preferred_skills`
      # (every skill still stages — this only TELLS the agent which to reach for). Empty prefs ⇒ untouched.
      def system_prompt
        parts = [ Rbrun.config(@session.tenant).system_prompt.to_s ]
        parts << workspace_note
        parts << preferred_skills_note
        parts << self_validation_note # autonomous scenario runs only
        parts.compact.reject(&:blank?).join("\n\n")
      end

      # Passing cwd to the SDK query() sets the tool base, but the SDK does NOT surface the absolute path
      # to the agent — so it still guesses (observed: it invented `/tmp/dummy-rails-check`). File tools
      # want ABSOLUTE paths, so the agent must be TOLD the exact checkout. Belt-and-suspenders with the
      # cwd option: the option makes relative paths + Bash correct, this stops the absolute-path guessing.
      def workspace_note
        dir = @session.worktree.checkout
        return nil if dir.blank?

        "Your working directory (Bash cwd, and where the repo is checked out) is `#{dir}`. Any absolute " \
          "path you pass to a file tool MUST be under `#{dir}` — do not guess; prefer paths relative to it."
      end

      def preferred_skills_note
        prefs = Array(@session.preferred_skills).map(&:to_s).reject(&:blank?)
        return nil if prefs.empty?

        "For this conversation, strongly prefer these skills and use them when they apply: " \
          "#{prefs.join(', ')}. They are staged in your workspace under .claude/skills/."
      end

      # In an autonomous run WITH a bound workflow (a scenario dogfood), the agent can't see the workflow
      # otherwise — so inject the steps (the validation checklist) and the self-validation directive. The
      # steps say WHAT to prove, never which tools to use (the dogfood exists to prove it reaches them).
      def self_validation_note
        return nil unless @session.auto?

        run = Rbrun::Workflow::Run.new(@session)
        return nil unless run.total.positive?

        steps = run.steps.each_with_index.map { |s, i| "#{i + 1}. #{s.title} — #{s.description}" }.join("\n")
        <<~TXT.strip
        ── Self-validated run ──
        You are running a workflow autonomously: do each step yourself AND validate it yourself, with no
        human to take your word — so your validation is worth only the PROOF behind it.

        Goal: #{@session.workflow&.goal}
        Steps (do each in order; the text after — is what you must prove, not which tool to use):
        #{steps}

        After you actually finish a step, call validate_step to mark it complete. Before approving, re-read
        what you just did — your tool calls and their results — and confirm the step is genuinely done. If
        nothing you did establishes it, redo it rather than approve it.
      TXT
      end

      # Clone the worktree's repo into the box before the turn — the whole point of a worktree is its
      # checkout, yet the box is born empty. Idempotent + box-loss-SELF-HEALING: `head_sha` is nil only
      # when the checkout has no repo (fresh box, or one lost and recreated), so this clones exactly once
      # per box lifecycle and skips otherwise. It does NOT swallow failures — a repo that can't be
      # provisioned is a broken conversation, so provision! RAISES and the turn fails loudly (the UI
      # surfaces it via flash). Bare worktrees (skills/scenarios) have no repo and provision! is a no-op.
      def ensure_provisioned
        return if @runtime # injected fake (tests) — no real box
        return if @session.worktree.bare?
        return if @session.worktree.head_sha.present?

        @session.worktree.provision!
      end

      def call_client(prompt)
        runtime = @runtime || Rbrun.runtime(tenant: @session.tenant, sandbox: @session.sandbox)
        ensure_provisioned
        # Reconstruct .claude history on a fresh/lost box BEFORE resume — the turn survives box loss.
        Rbrun::ClaudeSnapshot.new(@session).restore_if_lost!
        skills_dir = materialize_skills
        runtime.run(
          prompt:,
          system: system_prompt,
          tools: Rbrun::ApplicationTool.manifest,
          skills: skills_dir,
          mcp: materialize_mcp,
          resume: @session.sdk_session_id,
          auto: @session.auto?,
          cwd: @session.worktree.checkout,
          tool_handler: method(:run_tool),
          on_event: method(:ingest)
        )
      ensure
        FileUtils.remove_entry(skills_dir) if skills_dir && Dir.exist?(skills_dir)
        # Snapshot .claude AFTER the turn (best-effort, sync) so the snapshot lands before any reap.
        Rbrun::ClaudeSnapshot.new(@session).capture!
      end

      # Resolve this turn's external MCP servers (resolver if set, else the tenant's enabled DB rows),
      # keep them under the SDK tool ceiling, and materialize the mcp.json the runtime stages. Keyed on
      # the WORKTREE's repo (not a controller value — AgentTurn runs in a job). nil ⇒ no external servers.
      def materialize_mcp
        specs = Rbrun.mcp_servers_for(@session.tenant, @session.worktree.repo)
        return nil if specs.empty?

        capped = Rbrun::Mcp::ToolBudget.apply(specs,
                                              builtin_count: Rbrun::Mcp::ToolBudget::BUILTIN_COUNT,
                                              rbrun_count: Rbrun::ApplicationTool.manifest.size)
        {
          "servers"     => Rbrun::Mcp::Materializer.call(capped)["mcpServers"],
          "tools"       => capped.to_h { |s| [ s.name.to_s, s.tools ] },
          "permissions" => capped.to_h { |s| [ s.name.to_s, stringify_perms(s.tool_permissions) ] },
          "approved"    => approved_mcp_tools # full mcp__srv__tool names the user approved — allow on resume
        }
      end

      def stringify_perms(perms) = (perms || {}).to_h { |k, v| [ k.to_s, v.to_s ] }

      # External MCP tools the user has already approved this session — the resume run allows them so
      # the SERVER (not Ruby) executes them.
      def approved_mcp_tools
        @session.messages.gated.where(approval_status: "approved")
                .select { |m| m.payload["tool_kind"] == "mcp" }
                .filter_map { |m| m.payload["name"] }.uniq
      end

      # Materialize the acting tenant's current skill versions into a temp folder for the runtime to
      # stage. The DB is the source — never files/config. nil when the tenant has no skills.
      def materialize_skills
        require "tmpdir"
        skills = Rbrun::Skill.for_tenant(@session.tenant).where.not(current_version_id: nil).includes(:current_version)
        return nil if skills.empty?

        dir = Dir.mktmpdir("rbrun-skills-")
        skills.each { |skill| Rbrun::SkillArchive.unpack(skill.current_version.archive, into: File.join(dir, skill.slug)) }
        dir
      end

      def internal(text, kind)
        @session.messages.create!(role: "assistant", event_type: "internal", content: text, payload: { "kind" => kind })
      end

      # The nudge for a retried turn: the answer in flight was LOST (rewrite it), the actions were not
      # (don't redo them), and don't narrate the failure.
      def resume_prompt
        request = @session.messages.where(role: "user", event_type: "text").order(:id).last&.content
        [
          "The previous run failed on a technical error. The user asks you to resume.",
          ("The request you were answering was: \"#{request.to_s.strip}\"." if request && !request.to_s.empty?),
          "IMPORTANT: your in-flight answer was LOST — the user received nothing. Write the COMPLETE " \
          "answer now. Do NOT redo tool actions already executed; reuse their results. Do not mention " \
          "the interruption."
        ].compact.join("\n")
      end

      # The stdio tool bridge: log the tool_use, run it as the tenant, log the tool_result, return
      # { result:, is_error: } for the runtime to answer on the subprocess's stdin.
      def run_tool(event)
        id = event[:id]
        name = event[:name].to_s
        args = event[:args] || {}

        row("assistant", "tool_use", tool_use_id: id, payload: { "id" => id, "name" => name, "input" => args })
        tool = Rbrun::ApplicationTool.find(name)
        result = tool ? tool.in_session(@session).execute(**args) : { "error" => "unknown tool: #{name}" }
        failed = result.is_a?(Hash) && result["error"]
        log_tool_result(id, result, failed)
        { result:, is_error: !!failed }
      rescue StandardError => e
        err = { "error" => e.message }
        log_tool_result(id, err, true)
        { result: err, is_error: true }
      end

      # Persist non-tool events. tool_result rows for OUR tools come from run_tool; the SDK's built-ins
      # (Read/Write/Bash/…) arrive here off the message stream.
      def ingest(event)
        case event[:type]
        when "assistant"           then row("assistant", "text", content: event[:text].to_s) if event[:text].to_s != ""
        when "token"               then row("assistant", "token", content: event[:text].to_s, payload: event)
        when "session"             then record_session(event)
        when "needs_approval"      then record_needs_approval(event)
        when "mcp_status"          then record_mcp_status(event)
        when "builtin_tool_use"    then record_builtin_tool_use(event)
        when "builtin_tool_result" then record_builtin_tool_result(event)
        else row(nil, event[:type].to_s, payload: event)
        end
      end

      # The session id, the MOMENT the client emits it — a run that dies never reaches its result, and
      # a session captured at the end is a session lost.
      def record_session(event)
        row(nil, "session", payload: event)
        sid = event[:session_id]
        return if sid.nil? || sid.to_s.empty? || @session.sdk_session_id == sid

        @session.update_column(:sdk_session_id, sid)
      end

      def row(role, event_type, content: nil, payload: {}, **attrs)
        @session.messages.create!(role:, event_type:, content:, payload: payload || {}, **attrs)
      end

      def log_tool_result(tool_use_id, result, failed)
        row("tool", "tool_result", content: result.to_json, tool_use_id:,
            payload: { "tool_use_id" => tool_use_id, "result" => result, "is_error" => !!failed })
      end

      def record_builtin_tool_use(event)
        row("assistant", "tool_use", tool_use_id: event[:id],
            payload: { "id" => event[:id], "name" => event[:name].to_s, "input" => event[:input] || {} })
      end

      def record_builtin_tool_result(event)
        text = builtin_result_text(event[:content])
        row("tool", "tool_result", content: text, tool_use_id: event[:tool_use_id],
            payload: { "tool_use_id" => event[:tool_use_id], "result" => text, "is_error" => !!event[:is_error] })
      end

      def builtin_result_text(content)
        text =
          case content
          when String then content
          when Array  then content.filter_map { |b| b[:text] || b["text"] }.join("\n")
          else content.to_s
          end
        text.to_s.truncate(4_000, omission: "\n… (truncated)")
      end

      # A needs_approval tool reached the gate. The client already interrupted its run — this just
      # FREEZES the call as a durable pending tool_use row. name/input frozen here are the exact action
      # the owner decides on.
      # Readiness gate: an external MCP server that SETTLED as "failed" is a lost capability — log it
      # loud and persist a visible row (retryable), rather than the model silently proceeding without
      # the tool. "pending" is tolerated (still connecting).
      def record_mcp_status(event)
        failed = Array(event[:servers]).select { |s| (s[:status] || s["status"]).to_s == "failed" }
        return if failed.empty?

        names = failed.map { |s| s[:name] || s["name"] }
        Rails.logger.warn("[rbrun] mcp servers failed to connect: #{names.join(', ')}")
        row(nil, "mcp_status", payload: { "failed" => names })
      end

      def record_needs_approval(event)
        @gated = true
        row("assistant", "tool_use", tool_use_id: event[:tool_use_id], approval_status: "pending",
            payload: { "id" => event[:tool_use_id], "name" => event[:tool].to_s, "input" => event[:arguments] || {},
                       "tool_kind" => (event[:tool_kind] || "ruby").to_s })
      end
  end
end
