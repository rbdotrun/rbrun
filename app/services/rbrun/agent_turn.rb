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
      @session.messages.create!(role: "user", event_type: "text", content: content)
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

    def call_client(prompt)
      runtime = @runtime || Rbrun.runtime(tenant: @session.tenant, sandbox: @session.sandbox)
      skills_dir = materialize_skills
      runtime.run(
        prompt: prompt,
        system: Rbrun.config(@session.tenant).system_prompt,
        tools: Rbrun::ApplicationTool.manifest,
        skills: skills_dir,
        mcp: materialize_mcp,
        resume: @session.sdk_session_id,
        tool_handler: method(:run_tool),
        on_event: method(:ingest)
      )
    ensure
      FileUtils.remove_entry(skills_dir) if skills_dir && Dir.exist?(skills_dir)
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
      { result: result, is_error: !!failed }
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
      @session.messages.create!(role: role, event_type: event_type, content: content, payload: payload || {}, **attrs)
    end

    def log_tool_result(tool_use_id, result, failed)
      row("tool", "tool_result", content: result.to_json, tool_use_id: tool_use_id,
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
    def record_needs_approval(event)
      @gated = true
      row("assistant", "tool_use", tool_use_id: event[:tool_use_id], approval_status: "pending",
          payload: { "id" => event[:tool_use_id], "name" => event[:tool].to_s, "input" => event[:arguments] || {},
                     "tool_kind" => (event[:tool_kind] || "ruby").to_s })
    end
  end
end
