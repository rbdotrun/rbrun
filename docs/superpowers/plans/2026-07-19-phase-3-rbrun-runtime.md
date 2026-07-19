# Phase 3 — `rbrun-runtime` (AI runtime) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the AI-runtime sub-gem, `rbrun-runtime` — a `claude_sdk` runner that drives a self-contained Claude Agent SDK loop (`client.ts`) **inside a sandbox** over an NDJSON stdio bridge, services tools back in Ruby, and streams normalized events — proven by a **real agent turn on the local sandbox (offline)**.

**Architecture:** `Rbrun::Runtime.new(provider: :claude_sdk, sandbox:, config:)` resolves an adapter by constant lookup. The adapter stages `client.ts` + skills + settings + a per-turn `config.json` into the sandbox, runs `bun client.ts config.json` as a **detached sandbox process-session**, and drives it over the sandbox's `session_*` contract: stdout NDJSON events → `on_event`; `tool_request` lines → the Ruby `tool_handler` → written back on stdin; terminal state only from the client's own `result`/`error`. Because it speaks the **sandbox contract** (Phase 2), the exact same loop runs on `local` (offline) and `daytona`.

**Tech Stack:** Ruby (pure gem; stdlib `json`/`securerandom`), depends on `rbrun-sandbox`. The agentic loop itself is TypeScript (`@anthropic-ai/claude-agent-sdk` + `zod`) run by `bun` inside the sandbox.

## Global Constraints

- **The loop is not in Ruby.** `client.ts` (the Agent SDK `query()`) runs inside the sandbox as a detached `bun` process. Ruby = transport + tool execution + (host's) persistence. **Terminal state comes only from the client's `result`/`error` event, never the transport** (on stream drop: re-check the session command's exitCode; nil ⇒ still running ⇒ reconnect from the byte offset).
- **No registry, no self-registration.** `Rbrun::Runtime.new(provider:)` resolves by constant lookup (explicit `ADAPTERS` allowlist). Config-agnostic: the adapter takes an explicit `config:` hash, validates it, fails fast.
- **Sandbox-agnostic:** the Runner drives only the `Rbrun::Sandbox` contract (`write/exec!/session_*`), so it runs on `local` and `daytona` unchanged. It never references Daytona directly.
- **Secrets never outlive the turn:** the Anthropic key rides in `config.json` (deleted in `ensure`); the GitHub PAT is injected as **process-scoped env** in the run command (no global git config, nothing written to the host's real HOME).
- **HTTP invariant** (inherited): any HTTP is Faraday+async-http — but the runtime makes no HTTP of its own; the SDK inside the sandbox talks to Anthropic.
- **Dogfood:** `lib/tasks/rbrun/dogfood/runtime.rake`, one scenario, **never variabilized**. A **real** turn (real LLM + real local sandbox), no stubs.
- **Ruby 3.4.4**; gem `required_ruby_version >= 3.2`.

## Contract reference

```ruby
runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: <Rbrun::Sandbox adapter>,
                             config: { anthropic_api_key:, model: "sonnet", max_turns: 60, github_pat:, subprocess_timeout: 900 })
runtime.run(
  prompt:, system:, tools: [MANIFEST], skills: "<dir>"|nil, resume: nil,
  tool_handler: ->(event) { { result:, is_error: } },   # event = { type:"tool_request", id:, name:, args: }
  on_event:     ->(event) { ... }                        # normalized NDJSON events (symbol-keyed hashes)
) # => the terminal `result` event (symbol-keyed; structured_output string-keyed)

# MANIFEST entry: { name:, description:, needs_approval:, parameters: [ { name:, type:, description:, required:, items?: { type:, enum?: } } ] }
# event types: session · token · assistant · tool_request · needs_approval · builtin_tool_use · builtin_tool_result · result · error
```

---

## File Structure

**Created (under `gems/rbrun-runtime/`):**
- `rbrun-runtime.gemspec`, `Rakefile`, `README.md`
- `lib/rbrun/runtime.rb` — `module Rbrun::Runtime`, `Error`, `ADAPTERS`, `.new` dispatcher.
- `lib/rbrun/runtime/version.rb`
- `lib/rbrun/runtime/claude_sdk.rb` — the adapter (staging + run loop + tool bridge + `to_canonical`).
- `lib/rbrun/runtime/assets/client.ts` — the Agent SDK driver (ported from insiti, gem asset).
- `lib/rbrun/runtime/assets/tsconfig.json`
- `test/test_helper.rb` + `test/rbrun/runtime/*_test.rb` + `test/support/protocol_script.sh`

**Modified (rbrun-sandbox):**
- `gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb` — uniform timeout: wrap the follow's `Async::TimeoutError` as `Rbrun::Sandbox::TimeoutError` (Task 2).

**Created (engine repo):**
- `lib/tasks/rbrun/dogfood/runtime.rake`

**Test command for the gem:** `(cd gems/rbrun-runtime && bundle exec rake test)`.

---

### Task 1: Gem skeleton + dispatcher + `client.ts` asset

**Files:**
- Create: `gems/rbrun-runtime/rbrun-runtime.gemspec`, `Rakefile`, `README.md`, `lib/rbrun/runtime/version.rb`, `lib/rbrun/runtime.rb`, `lib/rbrun/runtime/assets/client.ts`, `lib/rbrun/runtime/assets/tsconfig.json`, `test/test_helper.rb`
- Test: `gems/rbrun-runtime/test/rbrun/runtime/dispatch_test.rb`

**Interfaces:**
- Produces: `Rbrun::Runtime.new(provider:, sandbox:, config:)`, `Rbrun::Runtime::Error`, `Rbrun::Runtime::VERSION`, and the staged `client.ts`/`tsconfig.json` assets.

- [ ] **Step 1: version + gemspec + Rakefile + README**

`gems/rbrun-runtime/lib/rbrun/runtime/version.rb`:

```ruby
# frozen_string_literal: true

module Rbrun
  module Runtime
    VERSION = "0.1.0"
  end
end
```

`gems/rbrun-runtime/rbrun-runtime.gemspec`:

```ruby
require_relative "lib/rbrun/runtime/version"

Gem::Specification.new do |spec|
  spec.name        = "rbrun-runtime"
  spec.version     = Rbrun::Runtime::VERSION
  spec.authors     = [ "Ben" ]
  spec.summary     = "AI runtime for rbrun: a sandboxed Claude Agent SDK runner behind one run(...) contract."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rbrun-sandbox"
end
```

`gems/rbrun-runtime/Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
```

`gems/rbrun-runtime/README.md`:

```markdown
# rbrun-runtime

The AI runtime for rbrun: a `claude_sdk` runner that drives a self-contained Claude Agent SDK loop
(`client.ts`) inside a sandbox over an NDJSON stdio bridge, services tools back in Ruby, and streams
normalized events. Depends on `rbrun-sandbox`; the loop runs on `local` and `daytona` unchanged.
```

- [ ] **Step 2: the dispatcher entrypoint**

`gems/rbrun-runtime/lib/rbrun/runtime.rb`:

```ruby
# frozen_string_literal: true

require "rbrun/runtime/version"
require "rbrun/runtime/claude_sdk"

module Rbrun
  # The AI-runtime family. `provider` selects the sandboxed RUNNER (claude_sdk today; codex/gemini
  # later). Resolves the adapter by constant lookup in this namespace; the adapter validates its own
  # config and fails fast. Depends on rbrun-sandbox (the loop runs inside a sandbox).
  #
  #   Rbrun::Runtime.new(provider: :claude_sdk, sandbox:, config: { anthropic_api_key: })
  module Runtime
    class Error < StandardError; end

    ADAPTERS = { claude_sdk: "ClaudeSdk" }.freeze

    def self.new(provider:, sandbox:, config: {})
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown runtime provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(sandbox: sandbox, config: config)
    end
  end
end
```

- [ ] **Step 3: stage the `client.ts` + `tsconfig.json` assets**

Copy the driver verbatim from the newer insiti source, then apply exactly two edits (it is otherwise generic and domain-free):

```bash
mkdir -p gems/rbrun-runtime/lib/rbrun/runtime/assets
cp /Users/ben/Desktop/insiti-files/app/clients/claude_sdk/agent/client.ts gems/rbrun-runtime/lib/rbrun/runtime/assets/client.ts
cp /Users/ben/Desktop/insiti-files/app/clients/claude_sdk/tsconfig.json  gems/rbrun-runtime/lib/rbrun/runtime/assets/tsconfig.json
```

Edit 1 — rename the MCP server (in `client.ts`):
```
const SERVER = "insitix";
```
→
```
const SERVER = "rbrun";
```

Edit 2 — neutralize the two French user-facing deny messages to English (in `canUseTool`):
```
message: `L'outil ${toolName} n'est pas disponible. Utilise uniquement tes outils dédiés.`,
```
→
```
message: `Tool ${toolName} is not available. Use only your dedicated tools.`,
```
and
```
message: "En attente de validation de l'utilisateur.",
```
→
```
message: "Awaiting user approval.",
```

Everything else in `client.ts` stays as-is (protocol, Zod schema build, `canUseTool` gate, `drain`, the flushing error handler). Confirm the emitted protocol matches the Runner: `session · token · assistant · tool_request · needs_approval · builtin_tool_use · builtin_tool_result · result · error`, and stdin `tool_response {id, result, is_error}`.

- [ ] **Step 4: failing dispatch test**

`gems/rbrun-runtime/test/test_helper.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "rbrun/runtime"
require "rbrun/sandbox"
```

`gems/rbrun-runtime/test/rbrun/runtime/dispatch_test.rb`:

```ruby
require "test_helper"

class RuntimeDispatchTest < Minitest::Test
  def test_unknown_provider_raises
    error = assert_raises(Rbrun::Runtime::Error) do
      Rbrun::Runtime.new(provider: :nope, sandbox: Object.new, config: {})
    end
    assert_match(/unknown runtime provider :nope/, error.message)
  end

  def test_dispatches_to_claude_sdk_adapter
    sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "rt-dispatch" })
    runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: sandbox,
                                 config: { anthropic_api_key: "sk-test" })
    assert_instance_of Rbrun::Runtime::ClaudeSdk, runtime
  ensure
    sandbox&.destroy!
  end

  def test_client_ts_asset_is_present
    path = File.expand_path("../../../lib/rbrun/runtime/assets/client.ts", __dir__)
    assert File.exist?(path), "client.ts asset must ship with the gem"
    assert_includes File.read(path), 'const SERVER = "rbrun"'
  end
end
```

- [ ] **Step 5: install + run (fails until the adapter exists, then the ClaudeSdk stub makes it pass)**

The entrypoint requires `rbrun/runtime/claude_sdk` — create a minimal stub so it loads, then Task 3 fills it:

`gems/rbrun-runtime/lib/rbrun/runtime/claude_sdk.rb`:

```ruby
# frozen_string_literal: true

module Rbrun
  module Runtime
    class ClaudeSdk
      def initialize(sandbox:, config: {})
        @sandbox = sandbox
        @config = config
      end
    end
  end
end
```

Run: `bundle install` (from repo root; the Gemfile glob picks up `gems/rbrun-runtime`), then:
`(cd gems/rbrun-runtime && bundle exec ruby -Ilib -Itest test/rbrun/runtime/dispatch_test.rb)`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 6: commit**

```bash
git add gems/rbrun-runtime Gemfile.lock
git commit -m "feat(runtime): rbrun-runtime skeleton — dispatcher + client.ts asset (ported)"
```

---

### Task 2: Uniform sandbox timeout (rbrun-sandbox patch)

The Runner reconnect logic must distinguish a **timeout** from a dropped stream. `local` already raises `Rbrun::Sandbox::TimeoutError`; `daytona`'s follow raises `Async::TimeoutError`. Make the contract uniform so the Runner rescues one type and never couples to `async`.

**Files:**
- Modify: `gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb`
- Test: `gems/rbrun-sandbox/test/rbrun/sandbox/daytona_timeout_test.rb`

**Interfaces:**
- Produces: `Rbrun::Sandbox::Daytona#session_logs_follow` raises `Rbrun::Sandbox::TimeoutError` (not `Async::TimeoutError`) on timeout.

- [ ] **Step 1: failing test (fake client that times out)**

`gems/rbrun-sandbox/test/rbrun/sandbox/daytona_timeout_test.rb`:

```ruby
require "test_helper"
require "async"

class DaytonaTimeoutTest < Minitest::Test
  class TimingOutClient
    def find_or_create(_labels) = { "id" => "box", "state" => "started" }
    def session_logs_follow(_id, _sid, _cid, skip: 0, timeout: nil)
      raise Async::TimeoutError, "boom"
    end
  end

  def test_follow_timeout_surfaces_as_sandbox_timeout_error
    adapter = Rbrun::Sandbox::Daytona.new(config: { api_key: "k", api_url: "u" },
                                          labels: { s: 1 }, client: TimingOutClient.new)
    assert_raises(Rbrun::Sandbox::TimeoutError) do
      adapter.session_logs_follow("s", "c", timeout: 1) { |_| false }
    end
  end
end
```

- [ ] **Step 2: run — verify it fails**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/daytona_timeout_test.rb)`
Expected: FAIL — the raw `Async::TimeoutError` propagates.

- [ ] **Step 3: wrap the timeout in the adapter**

In `gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb`, replace the `session_logs_follow` method with:

```ruby
      def session_logs_follow(session_id, cmd_id, skip: 0, timeout: nil, &block)
        @client.session_logs_follow(id, session_id, cmd_id, skip: skip, timeout: timeout, &block)
      rescue Async::TimeoutError => e
        raise TimeoutError, "session #{session_id}/#{cmd_id} follow timed out (#{e.message})"
      end
```

And add the require at the top of the file (after `require "tempfile"`):

```ruby
require "async"
```

- [ ] **Step 4: run — verify it passes; full sandbox suite stays green**

Run: `(cd gems/rbrun-sandbox && bundle exec rake test)`
Expected: PASS (28 runs, 0 failures).

- [ ] **Step 5: commit**

```bash
git add gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb gems/rbrun-sandbox/test/rbrun/sandbox/daytona_timeout_test.rb
git commit -m "fix(sandbox): daytona follow timeout surfaces as Rbrun::Sandbox::TimeoutError (uniform contract)"
```

---

### Task 3: ClaudeSdk adapter — config, staging, config.json, `to_canonical`

**Files:**
- Modify: `gems/rbrun-runtime/lib/rbrun/runtime/claude_sdk.rb` (replace the Task 1 stub)
- Test: `gems/rbrun-runtime/test/rbrun/runtime/claude_sdk_staging_test.rb`

**Interfaces:**
- Produces on `ClaudeSdk`: `#initialize(sandbox:, config:)` (fails fast without `anthropic_api_key`); private `#stage_client`, `#stage_skills(dir)`, `#stage_settings`, `#write_config_file(prompt:, system:, tools:, resume:) -> path`, `#run_command(config_path) -> String`, `#to_canonical(line) -> Hash|nil`, `#agent_dir`. Constants `AGENT_PACKAGE`, `CLIENT_TS`, `SERVER = "rbrun"`.

- [ ] **Step 1: write the failing test (staging drives the local sandbox for real)**

`gems/rbrun-runtime/test/rbrun/runtime/claude_sdk_staging_test.rb`:

```ruby
require "test_helper"
require "json"

class ClaudeSdkStagingTest < Minitest::Test
  def setup
    @sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "stage-#{Process.pid}" })
    @runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: @sandbox,
                                  config: { anthropic_api_key: "sk-ant-test", model: "sonnet", max_turns: 42 })
  end

  def teardown
    @sandbox&.destroy!
  end

  def test_config_fails_fast_without_api_key
    assert_raises(Rbrun::Runtime::Error) do
      Rbrun::Runtime.new(provider: :claude_sdk, sandbox: @sandbox, config: {})
    end
  end

  def test_write_config_file_carries_key_prompt_and_manifest
    path = @runtime.send(:write_config_file, prompt: "hi", system: "SYS", tools: [ { name: "add" } ], resume: nil)
    parsed = JSON.parse(@sandbox.read(path))
    assert_equal "sk-ant-test", parsed["api_key"]
    assert_equal "hi", parsed["prompt"]
    assert_equal "SYS", parsed["system_prompt"]
    assert_equal "sonnet", parsed["model"]
    assert_equal 42, parsed["max_turns"]
    assert_equal [ { "name" => "add" } ], parsed["manifest"]
  end

  def test_stage_settings_denies_web_tools
    @runtime.send(:stage_settings)
    settings = JSON.parse(@sandbox.read(File.join(@sandbox.workspace, ".claude", "settings.json")))
    assert_equal %w[WebFetch WebSearch], settings.dig("permissions", "deny")
  end

  def test_stage_skills_copies_a_skill_folder
    dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(dir, "demo"))
    File.write(File.join(dir, "demo", "SKILL.md"), "---\nname: demo\n---\nbody")
    @runtime.send(:stage_skills, dir)
    staged = File.join(@sandbox.workspace, ".claude", "skills", "demo", "SKILL.md")
    assert @sandbox.exist?(staged)
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_to_canonical_parses_ndjson_and_tolerates_garbage
    assert_equal({ type: "session", session_id: "x" }, @runtime.send(:to_canonical, %({"type":"session","session_id":"x"}\n)))
    assert_nil @runtime.send(:to_canonical, "not json")
  end

  def test_run_command_injects_github_pat_as_scoped_env
    rt = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: @sandbox,
                            config: { anthropic_api_key: "k", github_pat: "ghp_ABC" })
    cmd = rt.send(:run_command, "/box/agent/config.json")
    assert_includes cmd, "GH_TOKEN=ghp_ABC"
    assert_includes cmd, "GIT_CONFIG_COUNT=1"
    assert_includes cmd, "bun "
    refute_includes @runtime.send(:run_command, "/x"), "GH_TOKEN" # none when no pat
  end
end
```

Add `require "tmpdir"` and `require "fileutils"` at the top of the test.

- [ ] **Step 2: run — verify it fails**

Run: `(cd gems/rbrun-runtime && bundle exec ruby -Ilib -Itest test/rbrun/runtime/claude_sdk_staging_test.rb)`
Expected: FAIL (stub has no `write_config_file`).

- [ ] **Step 3: implement the adapter's config + staging half**

Replace `gems/rbrun-runtime/lib/rbrun/runtime/claude_sdk.rb` with (the run loop is added in Task 4):

```ruby
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

      # The driver's own package — the SDK + zod. NOT the app's toolchain (an artifact installs that
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
    end
  end
end
```

- [ ] **Step 4: run — verify it passes**

Run: `(cd gems/rbrun-runtime && bundle exec ruby -Ilib -Itest test/rbrun/runtime/claude_sdk_staging_test.rb)`
Expected: PASS (6 runs, 0 failures). (`stage_client` is not exercised here — it needs `bun`; Task 5's dogfood covers it live.)

- [ ] **Step 5: commit**

```bash
git add gems/rbrun-runtime/lib/rbrun/runtime/claude_sdk.rb gems/rbrun-runtime/test/rbrun/runtime/claude_sdk_staging_test.rb
git commit -m "feat(runtime): ClaudeSdk adapter — config, staging, config.json, PAT env, to_canonical"
```

---

### Task 4: ClaudeSdk adapter — the run loop + tool bridge + `run`

**Files:**
- Modify: `gems/rbrun-runtime/lib/rbrun/runtime/claude_sdk.rb` (add the public `run` + private `run_over_session` / `answer_tool_request`)
- Create: `gems/rbrun-runtime/test/support/protocol_script.rb` (a real local process that speaks the protocol)
- Test: `gems/rbrun-runtime/test/rbrun/runtime/claude_sdk_loop_test.rb`

**Interfaces:**
- Produces on `ClaudeSdk`: `#run(prompt:, system:, tools: [], skills: nil, resume: nil, tool_handler: nil, on_event: nil) -> Hash` (the terminal `result` event). Drives `@sandbox.session_*`; terminal only on `result`/`error`; reconnects on stream drop; `TimeoutError` on the subprocess cap.

The loop is exercised for real (no fake): a small **Ruby script**, run as a real command in the **local** sandbox, plays the client's side of the protocol — emits `session`, emits a `tool_request`, reads the `tool_response` from stdin, then emits `result`. This proves dispatch + the stdio tool bridge + terminal handling against a genuine detached process.

- [ ] **Step 1: the protocol script (real process, not a stub)**

`gems/rbrun-runtime/test/support/protocol_script.rb`:

```ruby
# frozen_string_literal: true
# Plays the client side of the NDJSON protocol for the loop test — a REAL detached process.
# Emits session → tool_request, waits for the tool_response on stdin, then emits result.
$stdout.sync = true
puts({ type: "session", session_id: "sess-xyz" }.to_json)
puts({ type: "assistant", text: "working" }.to_json)
puts({ type: "tool_request", id: "t1", name: "add", args: { a: 2, b: 3 } }.to_json)
line = $stdin.gets           # blocks until Ruby answers over the bridge
resp = JSON.parse(line)      # { "type":"tool_response","id":"t1","result":{...},"is_error":false }
puts({ type: "result", session_id: "sess-xyz", subtype: "success", errors: nil,
       stop_reason: "end_turn", structured_output: { "echoed" => resp["result"] } }.to_json)
```

Add `require "json"` at the top of the script.

- [ ] **Step 2: write the failing loop test**

`gems/rbrun-runtime/test/rbrun/runtime/claude_sdk_loop_test.rb`:

```ruby
require "test_helper"
require "json"

class ClaudeSdkLoopTest < Minitest::Test
  SCRIPT = File.expand_path("../../support/protocol_script.rb", __dir__)

  def setup
    @sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "loop-#{Process.pid}" })
    @runtime = Rbrun::Runtime.new(provider: :claude_sdk, sandbox: @sandbox, config: { anthropic_api_key: "k" })
  end

  def teardown
    @sandbox&.destroy!
  end

  def test_run_over_session_drives_events_and_the_tool_bridge
    events = []
    tool_calls = []
    handler = ->(event) do
      tool_calls << event
      { result: { sum: event[:args][:a] + event[:args][:b] }, is_error: false }
    end

    result = @runtime.send(
      :run_over_session,
      "ruby #{SCRIPT}",              # the "client" command — a real local process
      tool_handler: handler,
      on_event: ->(e) { events << e }
    )

    # tool bridge round-tripped
    assert_equal 1, tool_calls.size
    assert_equal "add", tool_calls.first[:name]
    # non-terminal, non-tool events reached on_event
    assert(events.any? { |e| e[:type] == "session" })
    assert(events.any? { |e| e[:type] == "assistant" && e[:text] == "working" })
    # terminal result returned, structured_output string-keyed and carrying our tool result
    assert_equal "success", result[:subtype]
    assert_equal({ "echoed" => { "sum" => 5 } }, result[:structured_output])
  end
end
```

- [ ] **Step 3: implement `run`, `run_over_session`, `answer_tool_request`**

In `gems/rbrun-runtime/lib/rbrun/runtime/claude_sdk.rb`, add the public `run` **above `private`**, and the loop methods in the private section:

```ruby
      # One turn. Stages everything, runs the client in a detached sandbox session, and streams its
      # events: tool_request → tool_handler (run in Ruby, answered on stdin); everything else →
      # on_event; result/error → terminal. Returns the terminal result event. The config.json (with
      # the api_key) is removed in ensure — the key never outlives the turn.
      def run(prompt:, system:, tools: [], skills: nil, resume: nil, tool_handler: nil, on_event: nil)
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
```

```ruby
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
```

- [ ] **Step 4: run — verify it passes**

Run: `(cd gems/rbrun-runtime && bundle exec ruby -Ilib -Itest test/rbrun/runtime/claude_sdk_loop_test.rb)`
Expected: PASS (1 run, 0 failures) — the local process emitted the protocol, the bridge answered `add(2,3)=5`, and the terminal result came back with `structured_output` string-keyed.

- [ ] **Step 5: whole gem suite + commit**

```bash
(cd gems/rbrun-runtime && bundle exec rake test)
git add gems/rbrun-runtime/lib/rbrun/runtime/claude_sdk.rb gems/rbrun-runtime/test/support/protocol_script.rb gems/rbrun-runtime/test/rbrun/runtime/claude_sdk_loop_test.rb
git commit -m "feat(runtime): ClaudeSdk run loop + stdio tool bridge + reconnect (real local-process test)"
```

---

### Task 5: Dogfood — a real agent turn on the Daytona sandbox

**Files:**
- Create: `lib/tasks/rbrun/dogfood/runtime.rake`
- Modify: `lib/tasks/rbrun/dogfood/support.rb` (add `load_env!`), `lib/tasks/rbrun/dogfood/sandbox_daytona.rake` (read `.env` not Rails credentials)

**Interfaces:**
- Consumes: `Rbrun::Runtime`, `Rbrun::Sandbox`, `Rbrun::Dogfood`. Adds `Rbrun::Dogfood.load_env!` (parses repo-root `.env` into `ENV` if unset). Reads `DAYTONA_API_KEY` / `DAYTONA_API_URL` / `ANTHROPIC_OAUTH_TOKEN` from `.env`.

This is the headline **dogfood runtime**: a real turn (real Claude + real **Daytona** box + the snapshot's `bun`), no engine, no stubs. Runs against Daytona because the snapshot bakes in `bun` (no host toolchain needed) and it's the real prod path. The **local** transport is already proven offline by Task 4's loop test. Creds come from `.env` — a secret store, not a scenario variable; no `:environment` (no Rails/DB) is needed.

- [ ] **Step 1: write the dogfood**

`lib/tasks/rbrun/dogfood/runtime.rake`:

```ruby
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
```

- [ ] **Step 2: add the `.env` loader to the dogfood spine**

Append to the `Rbrun::Dogfood` module in `lib/tasks/rbrun/dogfood/support.rb` (inside `module_function`):

```ruby
    # Load repo-root .env into ENV (only keys not already set). Dogfood creds live in .env — a secret
    # store, not a scenario variable. No dotenv gem; a five-line parser is enough.
    def load_env!(path = File.expand_path("../../../../.env", __dir__))
      return unless File.exist?(path)

      File.foreach(path) do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        key, _, value = line.partition("=")
        key = key.strip
        ENV[key] ||= value.strip.gsub(/\A["']|["']\z/, "")
      end
    end
```

(`__dir__` is `lib/tasks/rbrun/dogfood`, so `../../../../.env` is the repo root.)

- [ ] **Step 3: retrofit the Phase 2 daytona dogfood to read `.env`**

Replace the credentials preamble in `lib/tasks/rbrun/dogfood/sandbox_daytona.rake` — drop `:environment` and Rails credentials:

```ruby
  task :sandbox_daytona do
    dog = Rbrun::Dogfood
    dog.load_env!
    api_key = ENV["DAYTONA_API_KEY"].to_s
    api_url = ENV["DAYTONA_API_URL"].to_s
    abort "Missing .env creds (DAYTONA_API_KEY / DAYTONA_API_URL)." if api_key.empty?
```

and update the sandbox construction to use `api_key`/`api_url` locals:

```ruby
    box = Rbrun::Sandbox.new(
      provider: :daytona,
      config: { api_key: api_key, api_url: api_url },
      labels: { dogfood: "daytona" }
    )
```

- [ ] **Step 4: run the dogfood** (reads `.env`; uses the Daytona snapshot's bun — no host bun needed)

Run: `bin/rails app:dogfood:runtime`
Expected (with `.env` creds): a Daytona box comes up, `bun install` stages the SDK from the snapshot, Claude calls `add(2,3)` over the bridge, and it answers — all ✓, a real reply printed. Missing creds → a clean `abort`.

- [ ] **Step 5: full verification + commit**

```bash
(cd gems/rbrun-sandbox && bundle exec rake test)   # 28/0
(cd gems/rbrun-runtime && bundle exec rake test)   # green
bin/rails test                                     # engine 12/0
bin/rubocop                                         # 0 offenses
git add lib/tasks/rbrun/dogfood/runtime.rake lib/tasks/rbrun/dogfood/support.rb lib/tasks/rbrun/dogfood/sandbox_daytona.rake .gitignore
git commit -m "feat(dogfood): runtime — a real Claude turn in a Daytona box (Phase 3 gate); creds from .env"
```

---

## Self-Review

**1. Spec coverage (Phase 3 contract):**
- Runner transport decoupled from any model (injected `sandbox` + `config` + `on_event` + `tool_handler`) → Task 4 `run`/`run_over_session`. ✓
- `client.ts` shipped as a gem asset → Task 1. ✓
- staging (`bun install`, skill-staging, `.claude/settings.json`, per-turn `config.json` with the key deleted in `ensure`) → Tasks 3–4. ✓
- **GitHub PAT staging** into the sandbox per-turn → Task 3 `run_command` (process-scoped env; nothing written to the host's global git/HOME). ✓
- tool-manifest protocol → `tools:` param → `config.json.manifest` → client.ts MCP tools. ✓
- normalized `Event` + `to_canonical` → Task 3 `to_canonical` (the seam; claude_sdk's client.ts already emits canonical NDJSON). ✓
- `runtime_provider` family via `Rbrun::Runtime.new(provider:)` constant lookup, no registration → Task 1. ✓
- `claude_sdk` adapter → Tasks 3–4. ✓
- Deliverables: gem + unit tests for pure stream-parsing/dispatch (`to_canonical` direct; the loop against a real local process, not a stub) → Tasks 3–4. Dogfood gate `runtime.rake` (real turn on local, no engine) → Task 5. ✓
- Sandbox-agnostic loop (runs on local + daytona) → the Runner drives only the sandbox contract; the uniform-timeout patch (Task 2) is what lets it. ✓

**2. Placeholder scan:** No TODO/"handle edge cases"/"similar to". The Task 1 `ClaudeSdk` stub is explicitly replaced in Task 3. `client.ts` is a verbatim copy with two exact, shown edits. Every Ruby block is complete.

**3. Type/name consistency:** `Rbrun::Runtime.new(provider:, sandbox:, config:)`; `ClaudeSdk#run(prompt:, system:, tools:, skills:, resume:, tool_handler:, on_event:)`; events are symbol-keyed hashes with `:type`; `tool_handler` returns `{ result:, is_error: }`; `run_over_session` drives `@sandbox.session_create/session_exec/session_input/session_command/session_logs_follow` — the exact Phase 2 contract; `SERVER = "rbrun"` matches the `client.ts` edit and the `mcp__rbrun__` prefix the driver builds.

**Risk areas (validated by dogfood, not just unit tests):** live `bun install` + the real Claude turn + skill discovery + the SDK actually consulting `canUseTool` — exactly what Task 5's `runtime` gate exercises for real, and what a stubbed test structurally cannot.

**Note carried to Phase 4:** the engine's `AgentTurn` builds `tools:` from `ApplicationTool.manifest`, passes a `tool_handler` that runs `ApplicationTool.find(name).execute`, and an `on_event` that persists to `SessionMessage` + broadcasts — `Rbrun::Runtime#run` is the seam it calls, and `Rbrun.runtime`/`Rbrun.sandbox` (config-aware constructors over `Rbrun.build`) wire provider selection.
