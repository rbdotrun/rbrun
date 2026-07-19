# frozen_string_literal: true

require "json"
require "securerandom"

module Rbrun
  module Runtime
    # The claude_sdk runner. Knows nothing — no skills, no tools, no prompt: it stages a self-contained
    # Agent SDK driver (client.ts) into the sandbox and streams its JSONL events back. Everything the
    # run needs is uploaded every turn, unconditionally (idempotent by construction). Drives only the
    # Rbrun::Sandbox contract, so the same loop runs on local (offline) and daytona.
    class ClaudeSdk
      SERVER = "rbrun"

      # The driver's own package — the SDK + zod. NOT the app's toolchain (the built app installs that
      # itself). Pinned; staged and `bun install`ed every turn.
      AGENT_PACKAGE = {
        "name" => "rbrun-agent",
        "private" => true,
        "dependencies" => {
          "@anthropic-ai/claude-agent-sdk" => "^0.3",
          "zod" => "^3"
        }
      }.freeze

      CLIENT_TS = File.expand_path("assets/client.ts", __dir__)

      def initialize(sandbox:, config: {})
        @sandbox   = sandbox
        @api_key   = config[:anthropic_api_key]
        @model     = config[:model] || "sonnet"
        @max_turns = config[:max_turns] || 60
        @github_pat = config[:github_pat]
        @timeout   = Integer(config[:subprocess_timeout] || 900)
        @logger    = config[:logger]
        raise Error, "anthropic_api_key missing" if @api_key.nil? || @api_key.to_s.empty?
      end

      # One turn. Stages everything, runs the client in a detached sandbox session, and streams its
      # events: tool_request → tool_handler (run in Ruby, answered on stdin); everything else →
      # on_event; result/error → terminal. Returns the terminal result event. The config.json (with
      # the api_key) is removed in ensure — the key never outlives the turn.
      def run(prompt:, system:, tools: [], skills: nil, mcp: nil, resume: nil, tool_handler: nil, on_event: nil)
        config_path = nil
        begin
          stage_client
          stage_skills(skills)
          stage_settings
          config_path = write_config_file(prompt: prompt, system: system, tools: tools, resume: resume)
          run_over_session(run_command(config_path), tool_handler: tool_handler, on_event: on_event)
        ensure
          @sandbox.exec("rm -f #{config_path}") if config_path
        end
      end

      private

      # Sibling of the workspace (parallels Daytona's /home/daytona/agent) — outside the agent's cwd so
      # nothing it stages shows up in the working tree. Works for any adapter: dirname(workspace)/agent.
      def agent_dir = File.join(File.dirname(@sandbox.workspace), "agent")

      # Upload the driver + install its deps. Every turn, unconditionally — no "is it installed?"
      # check (the check would be the second truth, and the seconds do not matter).
      def stage_client
        @sandbox.write(File.join(agent_dir, "package.json"), JSON.pretty_generate(AGENT_PACKAGE))
        @sandbox.write(File.join(agent_dir, "client.ts"), File.read(CLIENT_TS))
        @sandbox.exec!("cd #{agent_dir} && bun install", timeout: 180)
      end

      # A skill is a folder; stage the tree under <workspace>/.claude/skills/ where the SDK's project
      # setting source finds it. This method never learns a skill's name.
      def stage_skills(dir)
        return unless dir && Dir.exist?(dir)

        dest = File.join(@sandbox.workspace, ".claude", "skills")
        uploads = Dir.glob(File.join(dir, "**/*")).select { |f| File.file?(f) }.map do |file|
          Rbrun::Sandbox::FileUpload.new(source: file, destination: File.join(dest, file.delete_prefix("#{dir}/")))
        end
        @sandbox.upload(uploads)
      end

      # The container is the confinement; the one product choice left is that the agent does not browse.
      def stage_settings
        @sandbox.write(
          File.join(@sandbox.workspace, ".claude", "settings.json"),
          JSON.pretty_generate("permissions" => { "deny" => [ "WebFetch", "WebSearch" ] })
        )
      end

      # The run config (api_key + prompt + client config), uploaded and deleted when the run ends — the
      # key never outlives the turn. Returns its remote path.
      def write_config_file(prompt:, system:, tools:, resume:)
        path = File.join(agent_dir, "config.json")
        @sandbox.write(path, {
          api_key: @api_key,
          prompt: prompt,
          system_prompt: system,
          model: @model,
          manifest: tools,
          resume: resume,
          max_turns: @max_turns
        }.to_json)
        path
      end

      # The detached run command. CLAUDE_CONFIG_DIR points the SDK at the workspace's project settings
      # (not the dev's ~/.claude). The GitHub PAT is injected as PROCESS-SCOPED env — a git credential
      # helper via GIT_CONFIG_* env, so nothing is written to the host's global git config or HOME.
      def run_command(config_path)
        workspace = @sandbox.workspace
        cmd = +"cd #{workspace} && CLAUDE_CONFIG_DIR=#{File.join(workspace, ".claude")} "
        if @github_pat && !@github_pat.to_s.empty?
          cmd << "GH_TOKEN=#{@github_pat} GITHUB_TOKEN=#{@github_pat} "
          cmd << "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper "
          cmd << %(GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' )
        end
        cmd << "bun #{File.join(agent_dir, "client.ts")} #{config_path}"
        cmd
      end

      def to_canonical(line)
        JSON.parse(line.strip, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end

      # structured_output is DATA (the model's JSON) — hand it back STRING-keyed so it stores as-is;
      # the envelope keeps its symbol keys.
      def stringify_output(event)
        out = event[:structured_output]
        out.is_a?(Hash) || out.is_a?(Array) ? event.merge(structured_output: deep_stringify(out)) : event
      end

      def deep_stringify(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = deep_stringify(v) }
        when Array then obj.map { |e| deep_stringify(e) }
        else obj
        end
      end

      # Drive the client as a DETACHED session command over the sandbox contract. If the log stream
      # drops, the process keeps running and we RECONNECT from `offset`. Terminal state comes only from
      # the client's own result/error — never the transport.
      def run_over_session(command, tool_handler:, on_event:)
        session_id = "turn-#{SecureRandom.hex(6)}"
        @sandbox.session_create(session_id)
        cmd_id = @sandbox.session_exec(session_id, command)

        result = nil
        error_message = nil
        terminal = false
        buf = +""
        offset = 0
        deadline = monotonic + @timeout

        dispatch = lambda do |chunk|
          buf << chunk
          while (nl = buf.index("\n"))
            line = buf.slice!(0..nl)
            event = to_canonical(line)
            next unless event

            case event[:type]
            when "tool_response" then next # our own stdin echoed by the session — never a client event
            when "result"        then result = stringify_output(event); error_message = nil; terminal = true
            when "error"         then error_message = event[:message]; terminal = true
            when "tool_request"  then answer_tool_request(session_id, cmd_id, event, tool_handler)
            else on_event&.call(event)
            end
          end
          terminal
        end

        until terminal
          remaining = deadline - monotonic
          raise Error, "client run timed out after #{@timeout}s" if remaining <= 0

          begin
            offset = @sandbox.session_logs_follow(session_id, cmd_id, skip: offset, timeout: remaining, &dispatch)
          rescue Rbrun::Sandbox::TimeoutError
            raise Error, "client run timed out after #{@timeout}s"
          rescue StandardError => e
            @logger&.debug { "[rbrun-runtime] log stream interrupted (#{e.class}: #{e.message}) — re-checking the command" }
          end
          break if terminal

          exit_code = @sandbox.session_command(session_id, cmd_id)["exitCode"]
          next if exit_code.nil? # still running, stream merely dropped → reconnect

          raise Error, "client exited #{exit_code} without a result"
        end

        raise Error, error_message if error_message

        result
      end

      # The tool bridge: run the requested tool in Ruby, write its result to the client's stdin.
      def answer_tool_request(session_id, cmd_id, event, tool_handler)
        response = tool_handler&.call(event) || { result: { error: "no tool handler" }, is_error: true }
        @sandbox.session_input(session_id, cmd_id, { type: "tool_response", id: event[:id], **response }.to_json + "\n")
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
