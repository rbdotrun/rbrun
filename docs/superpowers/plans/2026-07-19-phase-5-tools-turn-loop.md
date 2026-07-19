# Phase 5 — Engine host: tool base + turn loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the engine drive a real conversation: a `RubyLLM`-backed tool base + registry, an `AgentTurn` that turns runtime events into `SessionMessage` rows and services tools in Ruby, and `Session#run_turn` wiring `Rbrun::Runtime.run` → persistence with status transitions and gate freezing.

**Architecture:** `Rbrun::ApplicationTool < RubyLLM::Tool` holds a tool's schema + logic and derives its `manifest`/`find` from `Rbrun.tools` (engine built-ins + host-registered). `Session#run_turn` sets status `working`, runs `AgentTurn`, then flips to `done` or `needs_approval`. `AgentTurn` builds `Rbrun.runtime(sandbox: session.sandbox)` and calls `.run(tools: ApplicationTool.manifest, tool_handler: run_tool, on_event: ingest)`; `run_tool` logs the call, runs `ApplicationTool.find(name).in_session(session).execute(**args)`, logs the result; `ingest` persists every other event; a `needs_approval` event freezes a pending `tool_use` row and marks the turn gated.

**Tech Stack:** Rails engine, `ruby_llm` (Tool/Parameter + `ruby_llm-schema`), ActiveRecord, Minitest. Depends on Phases 3–4.

## Global Constraints

- **RubyLLM is engine-only, tool-base-only.** `Rbrun::ApplicationTool < RubyLLM::Tool`; never leak it into the sub-gems.
- **Tool names are demodulized snake_case.** Override `#name` (RubyLLM mangles `::` → `--`): `Rbrun::Tools::Identity` → `"identity"`.
- **Tool results are string-keyed data:** `{ "data" }`/arbitrary JSON on success, `{ "error" => … }` on failure; `run_tool` checks `result.is_a?(Hash) && result["error"]`.
- **Terminal state / gate:** a `needs_approval` event ENDS the run (the client interrupts itself); the turn is `needs_approval`, not `done`. Nothing waits — the frozen `tool_use` row is the durable record.
- **`Rbrun.tools`** = engine built-ins + host-registered (`Rbrun.register_tool`). `manifest`/`find` read it. (This is a plain tool list the host extends — not provider self-registration.)
- **Naming:** `Session`/`SessionMessage`; `in_session` (not `in_chat`).
- **Dogfood:** `lib/tasks/rbrun/dogfood/{session_turn,gate}.rake`, one scenario each, never variabilized; real turns through `Session#run_turn`, creds from `.env`.
- **Ruby 3.4.4.**

---

## File Structure

**Created:**
- `app/tools/rbrun/application_tool.rb`
- `app/tools/rbrun/tools/identity.rb`
- `app/services/rbrun/agent_turn.rb`
- `config/initializers/rbrun_tools.rb` (register built-ins)
- `lib/tasks/rbrun/dogfood/session_turn.rake`, `lib/tasks/rbrun/dogfood/gate.rake`
- Tests: `test/tools/rbrun/application_tool_test.rb`, `test/services/rbrun/agent_turn_test.rb`, `test/models/rbrun/session_run_turn_test.rb`

**Modified:**
- `rbrun.gemspec` — depend on `ruby_llm`.
- `lib/rbrun.rb` — `Rbrun.tools` + `Rbrun.register_tool`.
- `lib/rbrun/config.rb` — `system_prompt` flat knob (default generic).
- `app/models/rbrun/session.rb` — `#run_turn`.

---

### Task 1: `Rbrun::ApplicationTool` base + `Rbrun.tools` registry

**Files:**
- Modify: `rbrun.gemspec`, `lib/rbrun.rb`
- Create: `app/tools/rbrun/application_tool.rb`
- Test: `test/tools/rbrun/application_tool_test.rb`

**Interfaces:**
- Produces: `Rbrun.tools -> Array`, `Rbrun.register_tool(klass)`; `Rbrun::ApplicationTool` with `.parameter(name, items:, **)`, `.in_session(session)`, `.find(name)`, `.needs_approval!`/`.needs_approval?`, `.manifest`/`.manifest_entry(klass)`, `#execute`, `#error(msg)`, `#name` (demodulized), `IDENTITY_TOOL = "identity"`.

- [ ] **Step 1: depend on ruby_llm**

In `rbrun.gemspec`, add:

```ruby
  spec.add_dependency "ruby_llm"
```

Run `bundle install`.

- [ ] **Step 2: the tools registry**

In `lib/rbrun.rb`, add inside `class << self` (next to `sandbox`/`runtime`):

```ruby
    # The tool roster: engine built-ins + host-registered tools. ApplicationTool.manifest/find read it.
    def tools = @tools ||= []

    def register_tool(klass)
      tools << klass unless tools.include?(klass)
      klass
    end
```

- [ ] **Step 3: write the failing test**

`test/tools/rbrun/application_tool_test.rb`:

```ruby
require "test_helper"

class ApplicationToolTest < ActiveSupport::TestCase
  class Adder < Rbrun::ApplicationTool
    description "Add two integers."
    parameter :a, type: "integer", description: "first", required: true
    parameter :b, type: "integer", description: "second", required: true
    parameter :tags, type: "array", description: "labels", required: false,
              items: -> { { "type" => "string" } }
    def execute(a:, b:, tags: nil) = { "data" => { "sum" => a + b } }
  end

  class Dangerous < Rbrun::ApplicationTool
    description "Irreversible."
    needs_approval!
    def execute = { "data" => "boom" }
  end

  setup do
    @saved_tools = Rbrun.tools.dup
    Rbrun.instance_variable_set(:@tools, [ Adder, Dangerous ])
  end
  teardown { Rbrun.instance_variable_set(:@tools, @saved_tools) }

  test "name is demodulized snake_case" do
    assert_equal "adder", Adder.new.name
  end

  test "manifest carries name, description, gating, and typed params incl. array items" do
    entry = Rbrun::ApplicationTool.manifest.find { |e| e["name"] == "adder" }
    assert_equal "Add two integers.", entry["description"]
    assert_equal false, entry["needs_approval"]
    a = entry["parameters"].find { |p| p["name"] == "a" }
    assert_equal "integer", a["type"]
    assert a["required"]
    tags = entry["parameters"].find { |p| p["name"] == "tags" }
    assert_equal({ "type" => "string" }, tags["items"])
  end

  test "needs_approval! is reflected in the manifest" do
    entry = Rbrun::ApplicationTool.manifest.find { |e| e["name"] == "dangerous" }
    assert entry["needs_approval"]
  end

  test "find resolves a tool by name from the roster" do
    assert_equal Adder, Rbrun::ApplicationTool.find("adder")
    assert_nil Rbrun::ApplicationTool.find("nope")
  end

  test "in_session builds a tool bound to the session's tenant" do
    session = Rbrun::Session.create!(tenant: "acme")
    tool = Adder.in_session(session)
    assert_equal({ "data" => { "sum" => 5 } }, tool.execute(a: 2, b: 3))
  end
end
```

- [ ] **Step 4: run — verify it fails**

Run: `bin/rails test test/tools/rbrun/application_tool_test.rb`
Expected: FAIL (`Rbrun::ApplicationTool` undefined).

- [ ] **Step 5: implement the base**

`app/tools/rbrun/application_tool.rb`:

```ruby
require "ruby_llm"

module Rbrun
  # Base for every tool. A tool acts AS a tenant (the session's slug) and, for agentic tools, inside
  # a Session. It IS the operation (no service layer): it holds its schema + logic. RubyLLM is used
  # ONLY here (the tool DSL + ruby_llm-schema); it never reaches the sub-gems.
  class ApplicationTool < RubyLLM::Tool
    # RubyLLM::Parameter is name/type/description/required — no ITEM type for arrays. `items` (a
    # lambda, resolved at manifest time so a DB-backed enum doesn't query at class load) rides on the
    # Parameter itself, string-keyed (the manifest is JSON the client reads verbatim).
    class Parameter < RubyLLM::Parameter
      def initialize(name, items: nil, **options)
        @items = items
        super(name, **options)
      end

      def items = @items&.call
    end

    def self.parameter(name, **options)
      declared_parameters[name] = Parameter.new(name, **options)
    end

    # Metadata-only by default (find/manifest read .name/.description). An execution given no session
    # fails loudly on @session, never silently.
    def initialize(tenant: nil, session: nil)
      @tenant = tenant
      @session = session
      super()
    end

    # Build a tool for a turn: the Session is Tenanted, so it is BOTH the tenant slug and the session.
    def self.in_session(session) = new(tenant: session.tenant, session: session)

    IDENTITY_TOOL = "identity"

    # Resolve a tool NAME to its class (the gate needs this to run a frozen call). Only the roster.
    def self.find(name) = Rbrun.tools.find { |klass| klass.new.name == name }

    # Does this operation need the owner's go-ahead? DECLARED on the tool — a property of the
    # operation, not a per-caller setting.
    def self.needs_approval! = @needs_approval = true
    def self.needs_approval?  = @needs_approval == true

    # The roster serialized to the SDK-client shape (name + description + params + gating).
    def self.manifest = Rbrun.tools.map { |klass| manifest_entry(klass) }

    def self.manifest_entry(klass)
      { "name" => klass.new.name,
        "description" => klass.description.to_s,
        "needs_approval" => klass.needs_approval?,
        "parameters" => klass.declared_parameters.values.map do |p|
          entry = { "name" => p.name.to_s, "type" => p.type.to_s,
                    "description" => p.description.to_s, "required" => !!p.required }
          entry["items"] = p.items if p.respond_to?(:items) && p.items
          entry
        end }
    end

    # RubyLLM derives the name from the FULL class name (Rbrun::Tools::Identity → "rbrun--tools--
    # identity"). Demodulize so a namespaced engine tool gets a clean name ("identity").
    def name = self.class.name.to_s.demodulize.underscore.delete_suffix("_tool")

    private

    attr_reader :session

    # Acting identity — the session's tenant slug. One source; nil for a bare metadata instance.
    def tenant = @tenant

    # The ruby_llm recoverable-error convention: return, don't raise. Always string-keyed.
    def error(message) = { "error" => message }
  end
end
```

- [ ] **Step 6: run — verify it passes**

Run: `bin/rails test test/tools/rbrun/application_tool_test.rb`
Expected: PASS (5 runs, 0 failures). If `ruby_llm` raises on load requiring configuration, add `require "ruby_llm"` is enough — `RubyLLM::Tool` needs no client; if a config error appears, add an initializer `RubyLLM.configure { }` (empty) in `test/dummy/config/initializers`.

- [ ] **Step 7: commit**

```bash
git add rbrun.gemspec lib/rbrun.rb app/tools/rbrun/application_tool.rb test/tools/rbrun/application_tool_test.rb Gemfile.lock
git commit -m "feat(engine): Rbrun::ApplicationTool base (RubyLLM) + Rbrun.tools registry"
```

---

### Task 2: `Identity` built-in + `system_prompt` knob + registration

**Files:**
- Modify: `lib/rbrun/config.rb`
- Create: `app/tools/rbrun/tools/identity.rb`, `config/initializers/rbrun_tools.rb`
- Test: `test/tools/rbrun/identity_test.rb`

**Interfaces:**
- Produces: `Rbrun::Tools::Identity` (name `"identity"`, returns `{ "tenant", "session_id" }`); `Rbrun.config.system_prompt` (default generic); the engine registers `Identity` into `Rbrun.tools` at boot.

- [ ] **Step 1: the system_prompt knob**

In `lib/rbrun/config.rb`, add `:system_prompt` to `attr_accessor` and default it in `initialize`:

```ruby
    attr_accessor :database_connection, :subprocess_timeout, :github_pat, :tenancy_key, :system_prompt
```
and in `initialize`, after `@tenancy_key = "tenant"`:
```ruby
      @system_prompt = <<~PROMPT
        You are an assistant working inside a sandboxed workspace. Call the `identity` tool first to
        learn who you are working for. Use your tools to fulfil the request; when asked for a
        deliverable, build it. Never invent data — everything you present must come from your tools.
      PROMPT
```

- [ ] **Step 2: the Identity tool**

`app/tools/rbrun/tools/identity.rb`:

```ruby
module Rbrun
  module Tools
    # Who the turn works for: the current tenant slug and session id. The agent is told to call this
    # first (see Rbrun.config.system_prompt). Generic — hosts add richer identity tools of their own.
    class Identity < Rbrun::ApplicationTool
      description "Returns who you are working for: the current tenant and session id. Call this first."

      def execute = { "data" => { "tenant" => tenant, "session_id" => session&.id } }
    end
  end
end
```

- [ ] **Step 3: register built-ins at boot**

`config/initializers/rbrun_tools.rb`:

```ruby
# Register the engine's built-in tools. Host apps add theirs with Rbrun.register_tool(MyTool) in
# their own initializer. Runs after autoload so the tool classes are available.
Rails.application.config.to_prepare do
  Rbrun.register_tool(Rbrun::Tools::Identity)
end
```

- [ ] **Step 4: write + run the test**

`test/tools/rbrun/identity_test.rb`:

```ruby
require "test_helper"

module Rbrun
  module Tools
    class IdentityTest < ActiveSupport::TestCase
      test "identity is registered and returns tenant + session id" do
        assert_includes Rbrun.tools, Rbrun::Tools::Identity
        session = Rbrun::Session.create!(tenant: "acme")
        out = Identity.in_session(session).execute
        assert_equal "acme", out.dig("data", "tenant")
        assert_equal session.id, out.dig("data", "session_id")
      end

      test "default system_prompt names the identity tool" do
        assert_includes Rbrun.config.system_prompt, "identity"
      end
    end
  end
end
```

Run: `bin/rails test test/tools/rbrun/identity_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: commit**

```bash
git add lib/rbrun/config.rb app/tools/rbrun/tools/identity.rb config/initializers/rbrun_tools.rb test/tools/rbrun/identity_test.rb
git commit -m "feat(engine): Identity built-in tool + system_prompt knob + built-in registration"
```

---

### Task 3: `Rbrun::AgentTurn` (event sink + tool bridge + gate)

**Files:**
- Create: `app/services/rbrun/agent_turn.rb`
- Test: `test/services/rbrun/agent_turn_test.rb`

**Interfaces:**
- Produces: `Rbrun::AgentTurn.new(session:)` with `#run(content)`, `#gated?`. `run` creates a user `SessionMessage`, calls `Rbrun.runtime(sandbox:).run(...)` with `tool_handler: run_tool`, `on_event: ingest`; `run_tool(event) -> { result:, is_error: }`; `ingest(event)` persists rows; a `needs_approval` event freezes a pending `tool_use` row and sets gated.

- [ ] **Step 1: write the failing test (Runtime stubbed with a scripted fake)**

`test/services/rbrun/agent_turn_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class AgentTurnTest < ActiveSupport::TestCase
    # A scripted stand-in for a runtime adapter: plays events into on_event and round-trips the tool.
    class ToolCallingRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:)
        on_event.call({ type: "session", session_id: "sess-1" })
        on_event.call({ type: "assistant", text: "on it" })
        resp = tool_handler.call({ type: "tool_request", id: "t1", name: "identity", args: {} })
        raise "bridge broke" if resp[:is_error]
        on_event.call({ type: "result", stop_reason: "end_turn" })
        { type: "result", stop_reason: "end_turn" }
      end
    end

    class GatingRuntime
      def run(prompt:, system:, tools:, resume:, tool_handler:, on_event:)
        on_event.call({ type: "session", session_id: "sess-2" })
        on_event.call({ type: "needs_approval", tool: "dangerous", arguments: { "x" => 1 }, tool_use_id: "g1" })
        { type: "result", stop_reason: "awaiting_approval" }
      end
    end

    setup do
      @session = Session.create!(tenant: "acme")
      Rbrun.register_tool(Rbrun::Tools::Identity)
    end

    test "run persists the user row, the session id, tool_use+tool_result, and assistant text" do
      Rbrun.stub(:runtime, ToolCallingRuntime.new) do
        AgentTurn.new(session: @session).run("who am I?")
      end
      types = @session.messages.pluck(:event_type)
      assert_includes types, "text"        # user + assistant
      assert_includes types, "tool_use"
      assert_includes types, "tool_result"
      assert_equal "sess-1", @session.reload.sdk_session_id
      tr = @session.messages.find_by(event_type: "tool_result")
      refute tr.payload["is_error"]
      assert_equal "acme", JSON.parse(tr.content).dig("data", "tenant")
    end

    test "a needs_approval event freezes a pending tool_use row and marks the turn gated" do
      turn = AgentTurn.new(session: @session)
      Rbrun.stub(:runtime, GatingRuntime.new) { turn.run("do the dangerous thing") }
      assert turn.gated?
      frozen = @session.messages.gated.last
      assert frozen.approval_pending?
      assert_equal "dangerous", frozen.payload["name"]
      assert_equal({ "x" => 1 }, frozen.payload["input"])
      assert @session.messages.where(event_type: "tool_result", tool_use_id: "g1").none?
    end
  end
end
```

- [ ] **Step 2: run — verify it fails**

Run: `bin/rails test test/services/rbrun/agent_turn_test.rb`
Expected: FAIL (`Rbrun::AgentTurn` undefined).

- [ ] **Step 3: implement AgentTurn**

`app/services/rbrun/agent_turn.rb`:

```ruby
module Rbrun
  # ONE turn: builds the runtime in the session's sandbox, streams its events into the session's
  # event log, and services tool calls in Ruby. Everything the run emits is ingested verbatim; a
  # gated call freezes a durable row and ends the turn.
  class AgentTurn
    attr_reader :gated
    alias gated? gated

    def initialize(session:)
      @session = session
      @gated = false
    end

    def run(content)
      @session.messages.create!(role: "user", event_type: "text", content: content)
      Rbrun.runtime(sandbox: @session.sandbox).run(
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
```

- [ ] **Step 4: run — verify it passes**

Run: `bin/rails test test/services/rbrun/agent_turn_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: commit**

```bash
git add app/services/rbrun/agent_turn.rb test/services/rbrun/agent_turn_test.rb
git commit -m "feat(engine): AgentTurn — event sink + stdio tool bridge + gate freezing"
```

---

### Task 4: `Session#run_turn` (status transitions)

**Files:**
- Modify: `app/models/rbrun/session.rb`
- Test: `test/models/rbrun/session_run_turn_test.rb`

**Interfaces:**
- Produces: `Session#run_turn(content) -> AgentTurn` — `working!` → run → `done!` or (gated) `needs_approval!`; on error `failed!` + an `error` event row, then re-raise.

- [ ] **Step 1: write the failing test**

`test/models/rbrun/session_run_turn_test.rb`:

```ruby
require "test_helper"

module Rbrun
  class SessionRunTurnTest < ActiveSupport::TestCase
    class OkRuntime
      def run(**) = { type: "result", stop_reason: "end_turn" }
    end

    class GateRuntime
      def run(on_event:, **)
        on_event.call({ type: "needs_approval", tool: "x", arguments: {}, tool_use_id: "g" })
        { type: "result", stop_reason: "awaiting_approval" }
      end
    end

    class BoomRuntime
      def run(**) = raise("kaboom")
    end

    setup { @s = Session.create!(tenant: "acme") }

    test "a clean turn ends done" do
      Rbrun.stub(:runtime, OkRuntime.new) { @s.run_turn("hi") }
      assert @s.done?
    end

    test "a gated turn parks on needs_approval" do
      Rbrun.stub(:runtime, GateRuntime.new) { @s.run_turn("dangerous") }
      assert @s.needs_approval?
      assert_equal 1, @s.messages.gated.count
    end

    test "a failing turn flips to failed, logs an error row, and re-raises" do
      assert_raises(RuntimeError) do
        Rbrun.stub(:runtime, BoomRuntime.new) { @s.run_turn("break") }
      end
      assert @s.failed?
      assert @s.messages.exists?(event_type: "error")
    end
  end
end
```

- [ ] **Step 2: run — verify it fails**

Run: `bin/rails test test/models/rbrun/session_run_turn_test.rb`
Expected: FAIL (`undefined method 'run_turn'`).

- [ ] **Step 3: add `#run_turn`**

In `app/models/rbrun/session.rb`, add inside the class (after `#sandbox`):

```ruby
    # ONE turn, end to end: flip to working, run it, then land on done or (gated) needs_approval. A
    # failure flips to failed, logs an error row the agent/UI can read, and re-raises.
    def run_turn(content)
      working!
      turn = Rbrun::AgentTurn.new(session: self)
      turn.run(content)
      turn.gated? ? needs_approval! : done!
      turn
    rescue StandardError => e
      failed!
      messages.create!(role: "assistant", event_type: "error", payload: { "message" => e.message })
      raise
    end
```

- [ ] **Step 4: run — verify it passes; full engine suite stays green**

Run: `bin/rails test test/models/rbrun/session_run_turn_test.rb && bin/rails test`
Expected: PASS; whole engine suite green.

- [ ] **Step 5: commit**

```bash
git add app/models/rbrun/session.rb test/models/rbrun/session_run_turn_test.rb
git commit -m "feat(engine): Session#run_turn — status transitions + gate landing"
```

---

### Task 5: Dogfoods — real turns through `Session#run_turn`

**Files:**
- Create: `lib/tasks/rbrun/dogfood/session_turn.rake`, `lib/tasks/rbrun/dogfood/gate.rake`

**Interfaces:**
- Consumes: `Rbrun::Session`, `Rbrun::ApplicationTool`, `Rbrun::Dogfood`. Reconfigure providers from `.env` (Daytona + the OAuth token) — secrets, not scenario knobs.

Both run a REAL turn through `Session#run_turn` (real Claude, real Daytona box), like insiti's dogfoods. They register a demo tool, drive the turn, and read the persisted event log.

- [ ] **Step 1: the session_turn dogfood**

`lib/tasks/rbrun/dogfood/session_turn.rake`:

```ruby
# frozen_string_literal: true

require_relative "support"

# Phase 5 dogfood — a real turn through Session#run_turn (real Claude + real Daytona box). Registers
# a demo tool, drives one turn, and reads the persisted event log. Creds from .env.
#
#   bin/rails app:dogfood:session_turn

# A demo tool the agent must call (auto — no approval).
class DogfoodEcho < Rbrun::ApplicationTool
  description "Echo a short message back. Use this when asked to echo something."
  parameter :message, type: "string", description: "the text to echo", required: true
  def execute(message:) = { "data" => { "echoed" => message } }
end

namespace :dogfood do
  desc "Phase 5: a real turn runs through Session#run_turn, calls a tool, persists the log, ends done"
  task session_turn: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end
    Rbrun.register_tool(DogfoodEcho)

    session = Rbrun::Session.create!(tenant: "dogfood")
    begin
      session.run_turn("Call the dogfood_echo tool with the message 'pong', then tell me what it returned.")

      dog.header "the turn ran through the engine"
      dog.ok "status landed on done", session.reload.done?
      dog.ok "an assistant reply was persisted",
             session.messages.where(event_type: "text", role: "assistant").where.not(content: [ nil, "" ]).exists?

      dog.header "the tool bridge (via ApplicationTool)"
      call = session.messages.where(event_type: "tool_use").find { |m| m.payload["name"] == "dogfood_echo" }
      dog.ok "the agent called dogfood_echo", call.present?
      result = session.messages.find_by(event_type: "tool_result", tool_use_id: call&.tool_use_id)
      dog.ok "the tool ran and returned (no error)", result && !result.payload["is_error"]

      dog.header "no errors"
      dog.ok "no tool_result errored", session.messages.where(event_type: "tool_result").none? { |m| m.payload["is_error"] }
      dog.info "reply", session.messages.where(event_type: "text", role: "assistant").last&.content.to_s.squish[0, 160]
    ensure
      session.sandbox.destroy!
      session.destroy!
    end
  end
end
```

- [ ] **Step 2: run the session_turn dogfood**

Run: `bin/rails app:dogfood:session_turn`
Expected: all ✓ (status done, assistant reply, the tool called + ran via `ApplicationTool`, no errors).

- [ ] **Step 3: the gate dogfood**

`lib/tasks/rbrun/dogfood/gate.rake`:

```ruby
# frozen_string_literal: true

require_relative "support"

# Phase 5 dogfood — the approval gate, for real. A needs_approval! tool must PARK the run: the SDK's
# canUseTool has to fire and interrupt, and the engine must freeze a pending row with nothing run.
# The stubbed test can't see canUseTool; this can. Creds from .env.
#
#   bin/rails app:dogfood:gate

# An irreversible demo tool — declared needs_approval!.
class DogfoodDeploy < Rbrun::ApplicationTool
  description "Deploy the app to production. Irreversible."
  needs_approval!
  parameter :target, type: "string", description: "environment", required: false
  def execute(target: "production") = { "data" => "deployed to #{target}" }
end

namespace :dogfood do
  desc "Phase 5: a needs_approval! tool actually parks the run (frozen pending row, nothing executed)"
  task gate: :environment do
    dog = Rbrun::Dogfood
    dog.load_env!
    abort "Missing .env creds." if ENV["ANTHROPIC_OAUTH_TOKEN"].to_s.empty? || ENV["DAYTONA_API_KEY"].to_s.empty?

    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] } }
      c.runtime_provider = { default: :claude_sdk, claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"], model: "sonnet", max_turns: 12 } }
    end
    Rbrun.register_tool(DogfoodDeploy)

    session = Rbrun::Session.create!(tenant: "dogfood")
    begin
      session.run_turn("Deploy the app to production now, using the dogfood_deploy tool.")
      session.reload
      frozen = session.messages.approval_pending.last

      dog.header "the gate"
      dog.ok "the run PARKED on the owner (status=needs_approval)", session.needs_approval?
      dog.ok "a pending tool_use row was frozen", frozen.present?
      dog.ok "it froze dogfood_deploy, not something else", frozen&.payload&.dig("name") == "dogfood_deploy"
      dog.ok "NOTHING ran: no tool_result for the frozen call",
             frozen && session.messages.where(event_type: "tool_result", tool_use_id: frozen.tool_use_id).none?

      if !session.needs_approval? && session.messages.any? { |m| m.event_type == "tool_result" && m.payload.dig("result").to_s.include?("deployed") }
        puts "\n✗✗ THE GATE WAS BYPASSED — dogfood_deploy RAN without asking."
      end
    ensure
      session.sandbox.destroy!
      session.destroy!
    end
  end
end
```

- [ ] **Step 4: run the gate dogfood**

Run: `bin/rails app:dogfood:gate`
Expected: all ✓ (run parked, frozen pending row for `dogfood_deploy`, nothing ran).

- [ ] **Step 5: full verification + commit**

```bash
bin/rails test            # engine green
bin/rubocop               # 0 offenses
(cd gems/rbrun-sandbox && bundle exec rake test)   # 28/0
(cd gems/rbrun-runtime && bundle exec rake test)   # green
git add lib/tasks/rbrun/dogfood/session_turn.rake lib/tasks/rbrun/dogfood/gate.rake
git commit -m "feat(dogfood): session_turn + gate — real turns through Session#run_turn (Phase 5 gates)"
```

---

## Self-Review

**1. Spec coverage (Phase 5 contract):**
- `Rbrun::ApplicationTool < RubyLLM::Tool` + `manifest`/`find` + `in_session` tenancy → Task 1. ✓
- generic built-ins (identity + a demo tool) → Task 2 (`Identity`) + Task 5 (`DogfoodEcho`/`DogfoodDeploy`, proving host registration). ✓
- `AgentTurn` `ingest` sink + `run_tool` bridge → Task 3. ✓
- `Session#run_turn` wiring `Rbrun.runtime.run` (`tools: ApplicationTool.manifest`, `tool_handler`, `on_event`) → persistence + status transitions + gate freezing → Tasks 3–4. ✓
- host apps register their own tools (`Rbrun.register_tool`) → Task 1 + demonstrated in Task 5. ✓
- Dogfoods `session_turn` + `gate` (real turns through `Session#run_turn`) → Task 5. ✓

**2. Placeholder scan:** No TODO/"handle later". Every code block is complete. Task 1 Step 6 flags a *contingency* (an empty `RubyLLM.configure` initializer) only if `ruby_llm` demands config on load — an if-needed, not a placeholder.

**3. Type/name consistency:** `Rbrun::ApplicationTool` (`.in_session`, `.find`, `.manifest`, `.needs_approval!`, `#name` demodulized, `IDENTITY_TOOL`); `Rbrun.tools`/`register_tool`; `AgentTurn.new(session:)` / `#run` / `#gated?`; `run_tool` returns `{ result:, is_error: }`; `ingest` event `:type`s match the runtime's canonical events (`session`/`assistant`/`token`/`needs_approval`/`builtin_*`); `record_needs_approval` reads `event[:tool]`/`event[:arguments]`/`event[:tool_use_id]` — exactly the `needs_approval` shape `client.ts` emits. `Session#run_turn` uses the `status` enum bang methods from Phase 4.

**Risk areas (validated by dogfood):** `ruby_llm` load behavior + the real `canUseTool` gate firing — the `gate` dogfood is the only thing that proves the SDK actually interrupts on a `needs_approval!` tool (the stubbed `AgentTurn`/`run_turn` tests prove the Ruby freezing, not the SDK).

**Note carried to Phase 6:** `SessionMessage#decide_approval!`/`run_frozen_call!` (approve/reject a frozen row → run the tool → resume) + the `Artifact`/`SaveArtifactVersion` flow build directly on the gated rows and `ApplicationTool.find` established here.
