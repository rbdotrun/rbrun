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
      runtime = @runtime || Rbrun.runtime(sandbox: @session.sandbox)
      runtime.run(
        prompt: content,
        system: Rbrun.config.system_prompt,
        tools: Rbrun::ApplicationTool.manifest,
        resume: @session.sdk_session_id,
        tool_handler: method(:run_tool),
        on_event: method(:ingest)
      )
    end

    private

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
          payload: { "id" => event[:tool_use_id], "name" => event[:tool].to_s, "input" => event[:arguments] || {} })
    end
  end
end
