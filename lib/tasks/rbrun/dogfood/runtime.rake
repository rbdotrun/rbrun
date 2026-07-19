# frozen_string_literal: true

require "rbrun/runtime"
require "rbrun/sandbox"
require "tmpdir"
require "fileutils"
require_relative "support"

# Phase 3 dogfood — a REAL agent turn, for real (real Claude + real Daytona box + the snapshot's bun).
# No engine, no stubs. The agent is given ONE trivial tool (add) and a skill folder; it must call the
# tool over the stdio bridge and answer. Credentials come from .env (a secret store, not a scenario
# variable: dogfood is never parameterized).
#
#   bin/rails app:dogfood:runtime

namespace :dogfood do
  desc "Phase 3: a real Claude turn runs in a Daytona box, calls a tool over the bridge, and answers"
  task :runtime do
    dog = Rbrun::Dogfood
    dog.load_env!
    key = ENV["ANTHROPIC_OAUTH_TOKEN"].to_s
    daytona_key = ENV["DAYTONA_API_KEY"].to_s
    abort "Missing .env creds (ANTHROPIC_OAUTH_TOKEN / DAYTONA_API_KEY)." if key.empty? || daytona_key.empty?

    # A minimal skill folder (proves skills stage + the Skill tool is offered).
    skills = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(skills, "arithmetic"))
    File.write(File.join(skills, "arithmetic", "SKILL.md"),
               "---\nname: arithmetic\ndescription: How to add numbers with the add tool.\n---\nUse the `add` tool to sum two integers.")

    # ONE trivial in-memory tool, and its manifest entry.
    manifest = [ {
      name: "add", description: "Add two integers and return their sum.", needs_approval: false,
      parameters: [
        { name: "a", type: "integer", description: "first addend", required: true },
        { name: "b", type: "integer", description: "second addend", required: true }
      ]
    } ]
    tool_calls = []
    handler = lambda do |event|
      tool_calls << event
      a = event.dig(:args, :a).to_i
      b = event.dig(:args, :b).to_i
      { result: { sum: a + b }, is_error: false }
    end

    sandbox = Rbrun::Sandbox.new(
      provider: :daytona,
      config: { api_key: daytona_key, api_url: ENV["DAYTONA_API_URL"] },
      labels: { dogfood: "runtime" }
    )
    runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: sandbox,
                                 config: { anthropic_api_key: key, model: "sonnet", max_turns: 12 })

    events = []
    begin
      result = runtime.run(
        prompt: "Use the add tool to compute 2 + 3, then tell me the result as a sentence.",
        system: "You are a precise assistant. When arithmetic is needed, you MUST call the add tool rather than computing it yourself.",
        tools: manifest,
        skills: skills,
        tool_handler: handler,
        on_event: ->(e) { events << e }
      )

      dog.header "the turn ran for real"
      dog.ok "a session was emitted", events.any? { |e| e[:type] == "session" }
      dog.ok "the agent produced assistant text", events.any? { |e| e[:type] == "assistant" && !e[:text].to_s.empty? }

      dog.header "the tool bridge"
      dog.ok "the agent called `add` over the bridge", tool_calls.any? { |e| e[:name] == "add" }
      dog.ok "with a=2, b=3", tool_calls.any? { |e| e.dig(:args, :a).to_i == 2 && e.dig(:args, :b).to_i == 3 }

      dog.header "terminal"
      dog.ok "the run reached a terminal result", result.is_a?(Hash) && result[:type] == "result"
      dog.info "stop_reason", result[:stop_reason]
      dog.info "reply", events.select { |e| e[:type] == "assistant" }.map { |e| e[:text] }.join(" ").squeeze(" ")[0, 200]
    ensure
      sandbox.destroy!
      FileUtils.rm_rf(skills)
    end
  end
end
