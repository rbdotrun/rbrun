# Phase 2 — `rbrun-sandbox` (sandbox backend) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first provider sub-gem, `rbrun-sandbox` — a pure-Ruby gem exposing one normalized `exec / file / process-session` contract behind two adapters, `local` (offline host executor) and `daytona` (cloud, Faraday+async-http), selected by `Rbrun::Sandbox.new(provider:)`.

**Architecture:** A standalone gem under `gems/rbrun-sandbox` that **depends on nothing in rbrun**. `Rbrun::Sandbox.new(provider:, config:, labels:)` resolves an adapter by constant lookup in its own namespace and hands it the explicit config; the adapter validates its own config (fail-fast). `local` runs real processes in a host directory (so the agent loop runs offline in Phase 3); `daytona` pairs `Daytona::Client` (the wire) with `Workspace` (the contract), normalized to shared value objects.

**Tech Stack:** Ruby (pure gem, no Rails/ActiveSupport), Faraday + `async-http` + `async-http-faraday` + `faraday-multipart`, Minitest, Open3.

## Global Constraints

Every task's requirements implicitly include these (verbatim from the spec + Phase 1):

- **No registry, no self-registration.** `Rbrun::Sandbox.new(provider:)` resolves by constant lookup in the gem's own namespace via an explicit `ADAPTERS` allowlist. Nothing registers itself.
- **Pure gem, config-agnostic.** Adapters take an **explicit** `config:` hash and read no global state; each validates its own config and fails fast. `rbrun-sandbox` must not `require` anything from the engine (no `Rbrun::Config`, no `Rbrun.build`).
- **HTTP invariant:** all outbound HTTP uses **Faraday on the `async-http` adapter** (fork-safe under Falcon), never Typhoeus/libcurl or the official `daytona` gem. The **one** carve-out: `session_logs_follow` uses **raw `Async::HTTP::Internet`** (the Faraday async adapter buffers the whole body, deadlocking a follow that only closes on process exit).
- **Normalized contract** across both adapters: `exec`, `exec!`, `exec_stream`, `write`, `read`, `exist?`, `create_folder`, `upload`, `glob`, `destroy!`, `session_create`, `session_exec`, `session_input`, `session_command`, `session_logs_follow`; value objects `ExecResult(exit_code, stdout, stderr)` and `FileUpload(source, destination)`.
- **Dogfood:** `lib/tasks/rbrun/dogfood/<scenario>.rake`, one scenario per file, **never variabilized** — two backends ⇒ two files (`sandbox_local`, `sandbox_daytona`). Reuse the `Rbrun::Dogfood` spine from Phase 1.
- **Ruby 3.4.4**; the gem sets `required_ruby_version >= 3.2`.

## Value-object & contract reference (shared by both adapters)

```ruby
Rbrun::Sandbox::ExecResult(exit_code:, stdout:, stderr:)  # #success? => exit_code.to_i.zero?
Rbrun::Sandbox::FileUpload(source:, destination:)         # source = local path or IO

# adapter instance surface (both local + daytona):
#exec(command, timeout: 60) -> ExecResult
#exec!(command, timeout: 60) -> ExecResult (raises Rbrun::Sandbox::Error on non-zero)
#exec_stream(command, timeout: 600) { |line| } -> ExecResult   # one line per yield
#workspace -> String (absolute working dir inside the box)
#write(remote_path, content) / #read(remote_path) -> String / #exist?(remote_path) -> bool
#create_folder(path, mode = "755") / #upload(files) # files = [FileUpload]
#glob(dir) -> [relative paths]  / #destroy!
#session_create(session_id)
#session_exec(session_id, command) -> cmd_id
#session_input(session_id, cmd_id, data)
#session_command(session_id, cmd_id) -> { "exitCode" => Integer|nil }
#session_logs_follow(session_id, cmd_id, skip: 0, timeout: nil) { |chunk| break-if-truthy } -> Integer (bytes seen)
```

---

## File Structure

**Created (all under `gems/rbrun-sandbox/`):**

- `rbrun-sandbox.gemspec`, `Rakefile`, `README.md`
- `lib/rbrun/sandbox.rb` — entrypoint: `module Rbrun::Sandbox`, `Error`/`TimeoutError`, `ADAPTERS`, `.new` dispatcher.
- `lib/rbrun/sandbox/version.rb`
- `lib/rbrun/sandbox/exec_result.rb`, `lib/rbrun/sandbox/file_upload.rb`, `lib/rbrun/sandbox/line_buffer.rb`
- `lib/rbrun/sandbox/local.rb`
- `lib/rbrun/sandbox/daytona.rb`, `lib/rbrun/sandbox/daytona/client.rb`
- `test/test_helper.rb` + `test/rbrun/sandbox/*_test.rb`

**Created (engine repo):**

- `lib/tasks/rbrun/dogfood/sandbox_local.rake`, `lib/tasks/rbrun/dogfood/sandbox_daytona.rake`

**Modified:** none — the Phase 1 Gemfile glob auto-includes `gems/rbrun-sandbox` once its gemspec exists.

**Test command for the gem:** `(cd gems/rbrun-sandbox && bundle exec rake test)` — or a single file: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/local_test.rb)`.

---

### Task 1: Gem skeleton — entrypoint, value objects, dispatcher

**Files:**

- Create: `gems/rbrun-sandbox/rbrun-sandbox.gemspec`, `Rakefile`, `README.md`, `lib/rbrun/sandbox/version.rb`, `lib/rbrun/sandbox.rb`, `lib/rbrun/sandbox/exec_result.rb`, `lib/rbrun/sandbox/file_upload.rb`, `test/test_helper.rb`
- Test: `gems/rbrun-sandbox/test/rbrun/sandbox/dispatch_test.rb`

**Interfaces:**

- Produces: `Rbrun::Sandbox.new(provider:, config:, **opts)`, `Rbrun::Sandbox::Error`, `Rbrun::Sandbox::TimeoutError`, `Rbrun::Sandbox::ExecResult`, `Rbrun::Sandbox::FileUpload`, `Rbrun::Sandbox::VERSION`.

- [ ] **Step 1: Create the gemspec and version**

`gems/rbrun-sandbox/lib/rbrun/sandbox/version.rb`:

```ruby
# frozen_string_literal: true

module Rbrun
  module Sandbox
    VERSION = "0.1.0"
  end
end
```

`gems/rbrun-sandbox/rbrun-sandbox.gemspec`:

```ruby
require_relative "lib/rbrun/sandbox/version"

Gem::Specification.new do |spec|
  spec.name        = "rbrun-sandbox"
  spec.version     = Rbrun::Sandbox::VERSION
  spec.authors     = [ "rbdotrun" ]
  spec.summary     = "Sandbox backends for rbrun (local, daytona) behind one exec/file/session contract."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "async", ">= 2.0"
  spec.add_dependency "async-http", ">= 0.60"
  spec.add_dependency "async-http-faraday", ">= 0.12"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
end
```

`gems/rbrun-sandbox/README.md`:

````markdown
# rbrun-sandbox

Sandbox backends for rbrun behind one normalized `exec / file / process-session` contract.

```ruby
sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: 1 })
sandbox.exec("echo hi").stdout # => "hi\n"
```
````

Adapters: `local` (offline host executor), `daytona` (cloud, Faraday + async-http).
Pure Ruby — depends on nothing else in rbrun.

````

`gems/rbrun-sandbox/Rakefile`:

```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

task default: :test
````

- [ ] **Step 2: Write the value objects**

`gems/rbrun-sandbox/lib/rbrun/sandbox/exec_result.rb`:

```ruby
# frozen_string_literal: true

module Rbrun
  module Sandbox
    # The normalized result of one command, from any adapter.
    ExecResult = Data.define(:exit_code, :stdout, :stderr) do
      def success? = exit_code.to_i.zero?
    end
  end
end
```

`gems/rbrun-sandbox/lib/rbrun/sandbox/file_upload.rb`:

```ruby
# frozen_string_literal: true

module Rbrun
  module Sandbox
    # One file to put in a box: where it comes from here (a local path or an IO), where it goes there.
    FileUpload = Data.define(:source, :destination)
  end
end
```

- [ ] **Step 3: Write the entrypoint + dispatcher**

`gems/rbrun-sandbox/lib/rbrun/sandbox.rb`:

```ruby
# frozen_string_literal: true

require "rbrun/sandbox/version"
require "rbrun/sandbox/exec_result"
require "rbrun/sandbox/file_upload"
require "rbrun/sandbox/line_buffer"
require "rbrun/sandbox/local"
require "rbrun/sandbox/daytona"

module Rbrun
  # The sandbox backend family. Pure Ruby; depends on nothing else in rbrun.
  #
  #   Rbrun::Sandbox.new(provider: :local,   config: {},                    labels: { session: 42 })
  #   Rbrun::Sandbox.new(provider: :daytona, config: { api_key:, api_url:, dockerfile: }, labels: { session: 42 })
  #
  # Resolves the adapter by constant lookup in this namespace (explicit allowlist — no camelize of
  # attacker-supplied names, no ActiveSupport). The adapter validates its own config and fails fast.
  module Sandbox
    class Error < StandardError; end
    class TimeoutError < Error; end

    ADAPTERS = { local: "Local", daytona: "Daytona" }.freeze

    def self.new(provider:, config: {}, **opts)
      const_name = ADAPTERS.fetch(provider.to_sym) do
        raise Error, "unknown sandbox provider #{provider.inspect} (known: #{ADAPTERS.keys.join(", ")})"
      end
      const_get(const_name).new(config: config, **opts)
    end
  end
end
```

`gems/rbrun-sandbox/test/test_helper.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "rbrun/sandbox"
```

- [ ] **Step 4: Write the failing dispatch test**

`gems/rbrun-sandbox/test/rbrun/sandbox/dispatch_test.rb`:

```ruby
require "test_helper"

class DispatchTest < Minitest::Test
  def test_unknown_provider_raises
    error = assert_raises(Rbrun::Sandbox::Error) do
      Rbrun::Sandbox.new(provider: :nope, config: {})
    end
    assert_match(/unknown sandbox provider :nope/, error.message)
  end

  def test_dispatches_to_local_adapter
    sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "dispatch" })
    assert_instance_of Rbrun::Sandbox::Local, sandbox
  ensure
    sandbox&.destroy!
  end

  def test_exec_result_success
    assert Rbrun::Sandbox::ExecResult.new(exit_code: 0, stdout: "", stderr: "").success?
    refute Rbrun::Sandbox::ExecResult.new(exit_code: 1, stdout: "", stderr: "").success?
  end

  def test_file_upload_value_object
    fu = Rbrun::Sandbox::FileUpload.new(source: "/a", destination: "b")
    assert_equal "/a", fu.source
    assert_equal "b", fu.destination
  end
end
```

- [ ] **Step 5: Install the gem into the bundle**

Run: `bundle install`
Expected: `rbrun-sandbox` resolves as a path gem (the Phase 1 Gemfile glob picks it up), pulling in faraday/async deps.

- [ ] **Step 6: Run the dispatch test — fails then passes**

`local.rb`, `daytona.rb`, `line_buffer.rb` are required by the entrypoint but don't exist yet, so the require fails first.
Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/dispatch_test.rb)`
Expected initially: FAIL — `cannot load such file -- rbrun/sandbox/line_buffer`.

Create the three required files as **empty-but-valid stubs so the entrypoint loads** (they are filled in Tasks 2–6). Temporarily create:

`gems/rbrun-sandbox/lib/rbrun/sandbox/line_buffer.rb`, `local.rb`, `daytona.rb` each containing only:

```ruby
# frozen_string_literal: true
# (filled in a later task)
```

Then re-run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/dispatch_test.rb)`
Expected: `test_dispatches_to_local_adapter` ERRORS (`Local` is not a class yet) but the other 3 PASS. That is the expected mid-Task-1 state; `test_dispatches_to_local_adapter` goes green in Task 3.

- [ ] **Step 7: Commit**

```bash
git add gems/rbrun-sandbox Gemfile.lock
git commit -m "feat(sandbox): rbrun-sandbox gem skeleton — dispatcher + value objects"
```

---

### Task 2: `LineBuffer` (chunk → line normalizer)

**Files:**

- Create: `gems/rbrun-sandbox/lib/rbrun/sandbox/line_buffer.rb` (replace the Task 1 stub)
- Test: `gems/rbrun-sandbox/test/rbrun/sandbox/line_buffer_test.rb`

**Interfaces:**

- Produces: `Rbrun::Sandbox::LineBuffer.new(callable)` with `#feed(chunk)` (emits one call per complete line, incl. trailing `\n`) and `#flush` (emits any held partial line; idempotent).

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class LineBufferTest < Minitest::Test
  def setup
    @lines = []
    @buf = Rbrun::Sandbox::LineBuffer.new(->(line) { @lines << line })
  end

  def test_emits_one_call_per_complete_line
    @buf.feed("part-of-")
    assert_empty @lines
    @buf.feed("line-1\npart-of-line-2")
    assert_equal [ "part-of-line-1\n" ], @lines
    @buf.flush
    assert_equal [ "part-of-line-1\n", "part-of-line-2" ], @lines
  end

  def test_flush_is_idempotent
    @buf.feed("x\n")
    @buf.flush
    @buf.flush
    assert_equal [ "x\n" ], @lines
  end

  def test_multiple_lines_in_one_chunk
    @buf.feed("a\nb\nc\n")
    assert_equal [ "a\n", "b\n", "c\n" ], @lines
  end
end
```

- [ ] **Step 2: Run — verify it fails**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/line_buffer_test.rb)`
Expected: FAIL (`undefined method 'feed'` — stub is empty).

- [ ] **Step 3: Implement `LineBuffer`**

`gems/rbrun-sandbox/lib/rbrun/sandbox/line_buffer.rb`:

```ruby
# frozen_string_literal: true

module Rbrun
  module Sandbox
    # Chunk-to-line normalizer for exec_stream callbacks. Underlying transports deliver bytes in
    # arbitrary chunks; callers want one call per line. Feed raw chunks; the buffer emits complete
    # lines (including the trailing "\n") as they are seen. On stream close call #flush for any
    # trailing partial line.
    class LineBuffer
      def initialize(callback)
        @callback = callback
        @partial  = String.new
      end

      def feed(chunk)
        return if @callback.nil? || chunk.nil? || chunk.empty?

        @partial << chunk
        while (idx = @partial.index("\n"))
          line = @partial.slice!(0..idx) # includes the newline
          @callback.call(line)
        end
      end

      def flush
        return if @callback.nil? || @partial.empty?

        @callback.call(@partial.dup)
        @partial.clear
      end
    end
  end
end
```

- [ ] **Step 4: Run — verify it passes**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/line_buffer_test.rb)`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add gems/rbrun-sandbox/lib/rbrun/sandbox/line_buffer.rb gems/rbrun-sandbox/test/rbrun/sandbox/line_buffer_test.rb
git commit -m "feat(sandbox): LineBuffer chunk→line normalizer"
```

---

### Task 3: `Local` adapter — filesystem + exec

**Files:**

- Modify: `gems/rbrun-sandbox/lib/rbrun/sandbox/local.rb` (replace the stub with the filesystem+exec surface; sessions are added in Task 4)
- Test: `gems/rbrun-sandbox/test/rbrun/sandbox/local_test.rb`

**Interfaces:**

- Consumes: `ExecResult`, `FileUpload`, `LineBuffer` (Tasks 1–2).
- Produces: `Rbrun::Sandbox::Local.new(config:, labels:)` with `#workspace`, `#exec`, `#exec!`, `#exec_stream`, `#write`, `#read`, `#exist?`, `#create_folder`, `#upload`, `#glob`, `#destroy!`. (Session methods land in Task 4.)

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class LocalTest < Minitest::Test
  def setup
    @sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "local-#{Process.pid}" })
  end

  def teardown
    @sandbox&.destroy!
  end

  def test_exec_returns_normalized_result
    result = @sandbox.exec("echo hi")
    assert_instance_of Rbrun::Sandbox::ExecResult, result
    assert result.success?
    assert_equal "hi\n", result.stdout
  end

  def test_exec_bang_raises_on_failure
    assert_raises(Rbrun::Sandbox::Error) { @sandbox.exec!("exit 3") }
  end

  def test_write_read_exist
    @sandbox.write("dir/a.txt", "hello")
    assert @sandbox.exist?("dir/a.txt")
    assert_equal "hello", @sandbox.read("dir/a.txt")
    refute @sandbox.exist?("dir/missing.txt")
  end

  def test_upload_many_files
    src = Tempfile.new("rbrun-src")
    src.write("payload")
    src.close
    @sandbox.upload([ Rbrun::Sandbox::FileUpload.new(source: src.path, destination: "up/x.txt") ])
    assert_equal "payload", @sandbox.read("up/x.txt")
  ensure
    src&.unlink
  end

  def test_glob_lists_files_relative_sorted
    @sandbox.write("a.txt", "1")
    @sandbox.write("sub/b.txt", "2")
    assert_equal [ "a.txt", "sub/b.txt" ], @sandbox.glob(".")
  end

  def test_exec_stream_yields_lines
    lines = []
    result = @sandbox.exec_stream("printf 'l1\\nl2\\n'") { |line| lines << line }
    assert_equal [ "l1\n", "l2\n" ], lines
    assert result.success?
  end

  def test_destroy_removes_the_box
    @sandbox.write("x", "1")
    root = @sandbox.workspace
    @sandbox.destroy!
    refute File.exist?(root)
  end
end
```

Add `require "tempfile"` at the top of the test file (used by `test_upload_many_files`).

- [ ] **Step 2: Run — verify it fails**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/local_test.rb)`
Expected: FAIL (`Local` stub has no methods).

- [ ] **Step 3: Implement the `Local` filesystem + exec surface**

`gems/rbrun-sandbox/lib/rbrun/sandbox/local.rb`:

```ruby
# frozen_string_literal: true

require "open3"
require "fileutils"
require "tempfile"
require "timeout"

module Rbrun
  module Sandbox
    # Runs a "sandbox" as a plain directory on the local host — real processes, real files, no cloud.
    # The offline executor: it runs the actual agent loop (bun client.ts) for dogfood + CI without
    # provisioning Daytona. One box == one directory under `config[:root]`, addressed by labels.
    class Local
      ROOT = "workspace"

      def initialize(config: {}, labels: {})
        base   = config[:root] || File.join(Dir.tmpdir, "rbrun-sandboxes")
        @root  = File.join(base, slugify(labels))
        @sessions = {}
        FileUtils.mkdir_p(workspace)
      end

      def id = @root

      # The box's working root (parallels Daytona's /home/daytona/workspace).
      def workspace = File.join(@root, ROOT)

      def exec(command, timeout: 60)
        Timeout.timeout(timeout) do
          out, err, status = Open3.capture3(command, chdir: workspace)
          ExecResult.new(exit_code: status.exitstatus, stdout: out, stderr: err)
        end
      end

      def exec!(command, timeout: 60)
        result = exec(command, timeout: timeout)
        return result if result.success?

        raise Error, "#{command.inspect} exited #{result.exit_code}: #{result.stderr.to_s.lines.last(5).join}"
      end

      # popen2e — combined stdout+stderr on one pipe, matching Daytona's merged session stream.
      def exec_stream(command, timeout: 600, &block)
        buf = String.new
        line_buffer = LineBuffer.new(->(line) { buf << line; block&.call(line) })
        Timeout.timeout(timeout) do
          Open3.popen2e(command, chdir: workspace) do |_stdin, out_err, wait_thr|
            until out_err.eof?
              line_buffer.feed(out_err.readpartial(4096))
            end
            line_buffer.flush
            ExecResult.new(exit_code: wait_thr.value.exitstatus, stdout: buf, stderr: "")
          end
        end
      end

      def write(remote_path, content)
        path = absolute(remote_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, content.to_s)
      end

      def read(remote_path) = File.binread(absolute(remote_path))

      def exist?(remote_path) = File.exist?(absolute(remote_path))

      def create_folder(path, _mode = "755") = FileUtils.mkdir_p(absolute(path))

      def upload(files)
        files.each do |f|
          dest = absolute(f.destination)
          FileUtils.mkdir_p(File.dirname(dest))
          content = f.source.respond_to?(:read) ? f.source.read : File.binread(f.source)
          File.binwrite(dest, content)
        end
      end

      def glob(dir)
        base = absolute(dir)
        Dir.glob("**/*", base: base).select { |rel| File.file?(File.join(base, rel)) }.sort
      end

      def destroy!
        FileUtils.rm_rf(@root)
        @sessions.clear
        nil
      end

      private

      def absolute(path)
        path.start_with?(@root) ? path : File.join(workspace, path)
      end

      def slugify(labels)
        return "default" if labels.nil? || labels.empty?

        labels.map { |k, v| "#{k}-#{v}" }.join("_").gsub(/[^a-zA-Z0-9_\-]/, "-")
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
```

- [ ] **Step 4: Run — verify it passes**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/local_test.rb)`
Expected: PASS (7 runs, 0 failures). Re-run the dispatch test — `test_dispatches_to_local_adapter` now passes too.

- [ ] **Step 5: Commit**

```bash
git add gems/rbrun-sandbox/lib/rbrun/sandbox/local.rb gems/rbrun-sandbox/test/rbrun/sandbox/local_test.rb
git commit -m "feat(sandbox): Local adapter — filesystem + exec/exec_stream"
```

---

### Task 4: `Local` adapter — process sessions

**Files:**

- Modify: `gems/rbrun-sandbox/lib/rbrun/sandbox/local.rb` (add the session methods inside the class, before `private`)
- Test: `gems/rbrun-sandbox/test/rbrun/sandbox/local_session_test.rb`

**Interfaces:**

- Produces on `Local`: `#session_create(session_id)`, `#session_exec(session_id, command) -> cmd_id`, `#session_input(session_id, cmd_id, data)`, `#session_command(session_id, cmd_id) -> { "exitCode" => Integer|nil }`, `#session_logs_follow(session_id, cmd_id, skip:, timeout:) { |chunk| } -> Integer`.

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

class LocalSessionTest < Minitest::Test
  def setup
    @sandbox = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { session: "sess-#{Process.pid}" })
  end

  def teardown
    @sandbox&.destroy!
  end

  def test_session_streams_stdin_to_stdout_and_reports_exit
    @sandbox.session_create("s1")
    # `cat` echoes stdin to stdout, then exits when stdin closes.
    cmd_id = @sandbox.session_exec("s1", "cat")

    @sandbox.session_input("s1", cmd_id, "ping\n")

    seen = String.new
    bytes = @sandbox.session_logs_follow("s1", cmd_id, skip: 0, timeout: 5) do |chunk|
      seen << chunk
      seen.include?("ping") # stop following once we've observed the echo
    end

    assert_includes seen, "ping"
    assert bytes.positive?
  end

  def test_session_command_reports_exit_code_after_completion
    @sandbox.session_create("s2")
    cmd_id = @sandbox.session_exec("s2", "exit 0")
    # drain to completion
    @sandbox.session_logs_follow("s2", cmd_id, timeout: 5) { |_| false }
    assert_equal 0, @sandbox.session_command("s2", cmd_id)["exitCode"]
  end

  def test_logs_follow_skip_resumes_without_replay
    @sandbox.session_create("s3")
    cmd_id = @sandbox.session_exec("s3", "printf 'AAAAABBBBB'")
    first = String.new
    offset = @sandbox.session_logs_follow("s3", cmd_id, skip: 0, timeout: 5) do |c|
      first << c
      first.length >= 5 # stop after the first 5 bytes are seen
    end
    # resume from the offset already consumed — must not replay the A's
    rest = String.new
    @sandbox.session_logs_follow("s3", cmd_id, skip: offset, timeout: 5) { |c| rest << c; false }
    refute_includes rest, "AAAAA"
    assert_includes rest, "BBBBB"
  end
end
```

- [ ] **Step 2: Run — verify it fails**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/local_session_test.rb)`
Expected: FAIL (`undefined method 'session_create'`).

- [ ] **Step 3: Add the session methods**

In `gems/rbrun-sandbox/lib/rbrun/sandbox/local.rb`, insert these methods **after `destroy!` and before `private`**:

```ruby
      # ── process sessions ─────────────────────────────────────────────
      # A long-lived detached process: spawn it with stdin piped and stdout+stderr merged to a log
      # file; stream the log as it grows, write stdin, poll exit — the local mirror of Daytona's
      # process-session transport the Runner drives.
      def session_create(session_id)
        @sessions[session_id] ||= {}
        nil
      end

      def session_exec(session_id, command)
        session = (@sessions[session_id] ||= {})
        cmd_id  = "cmd-#{session.size + 1}"
        log     = Tempfile.new([ "rbrun-local-session", ".log" ])
        log.close
        stdin_r, stdin_w = IO.pipe
        pid = Process.spawn(command, in: stdin_r, out: log.path, err: %i[child out], chdir: workspace)
        stdin_r.close
        session[cmd_id] = { stdin: stdin_w, log: log.path, thread: Process.detach(pid) }
        cmd_id
      end

      def session_input(session_id, cmd_id, data)
        io = @sessions.fetch(session_id).fetch(cmd_id)[:stdin]
        io.write(data)
        io.flush
        nil
      end

      def session_command(session_id, cmd_id)
        thr = @sessions.fetch(session_id).fetch(cmd_id)[:thread]
        { "exitCode" => (thr.alive? ? nil : thr.value.exitstatus) }
      end

      # Follow the command's merged output. `skip` bytes are dropped first (resume offset). Returns
      # total bytes seen. Stops when the command exits and the log is fully read, or when the block
      # returns truthy (the caller signalled terminal).
      def session_logs_follow(session_id, cmd_id, skip: 0, timeout: nil)
        entry    = @sessions.fetch(session_id).fetch(cmd_id)
        seen     = 0
        pos      = 0
        deadline = timeout ? monotonic + timeout : nil
        loop do
          size  = File.size?(entry[:log]).to_i
          chunk = size > pos ? IO.binread(entry[:log], nil, pos) : nil
          if chunk && !chunk.empty?
            pos  += chunk.bytesize
            prev  = seen
            seen += chunk.bytesize
            emit  = chunk
            if skip.positive? && seen <= skip
              emit = ""
            elsif skip.positive? && prev < skip
              emit = chunk.byteslice(skip - prev..) || ""
            end
            break if !emit.empty? && yield(emit)
          else
            done = !entry[:thread].alive?
            break if done && pos >= File.size?(entry[:log]).to_i
            raise TimeoutError, "session #{session_id}/#{cmd_id} follow timed out" if deadline && monotonic > deadline

            sleep 0.05
          end
        end
        seen
      end
```

- [ ] **Step 4: Run — verify it passes**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/local_session_test.rb)`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add gems/rbrun-sandbox/lib/rbrun/sandbox/local.rb gems/rbrun-sandbox/test/rbrun/sandbox/local_session_test.rb
git commit -m "feat(sandbox): Local adapter — process sessions (spawn/stream/input/poll)"
```

---

### Task 5: `Daytona::Client` — the Faraday + async-http wire

**Files:**

- Modify: `gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb` (replace stub — define the `Daytona` module namespace + `require` its client; the adapter class comes in Task 6)
- Create: `gems/rbrun-sandbox/lib/rbrun/sandbox/daytona/client.rb`
- Test: `gems/rbrun-sandbox/test/rbrun/sandbox/daytona_client_test.rb`

**Interfaces:**

- Produces: `Rbrun::Sandbox::Daytona::Client.new(api_key:, api_url:, dockerfile: nil, snapshot_name: nil, cpu: nil, memory: nil, disk: nil)` with `Client::Error` and the full wire surface: `find_or_create(labels)`, `find_by_labels`, `await_started`, `request_start`, `destroy(id)`, snapshot machinery (`snapshot_ref`, `ensure_snapshot`, `create_snapshot`, `snapshot_state`, `await_snapshot_active`), `exec(id, command, timeout:)`, `download(id, path)`, `create_session`, `session_exec`, `session_input`, `session_command`, `session_logs_follow`, `create_folder`, `upload(id, path, source)`.

This is the snapshot-based `Daytona::Client`. Its design: (1) credentials + **the snapshot Dockerfile and resources come from constructor kwargs** (`dockerfile`/`snapshot_name`/`cpu`/`memory`/`disk`), never `Rails.application.credentials` and never a hardcoded image — **the host injects its own Dockerfile**; a minimal bun+shell `DEFAULT_DOCKERFILE` applies when none is given; (2) no bundled document-conversion/base64 embedding — hosts add tooling in their own Dockerfile; (3) module namespace `Rbrun::Sandbox::Daytona`; (4) core Ruby only, no ActiveSupport (`nil?/empty?` not `blank?`, `arr.include?` not `.in?(arr)`); (5) `require "json"/"digest"/"cgi"` at the top. The box is a self-built, content-addressed Daytona **snapshot** (built server-side from the Dockerfile string, reused across turns).

- [ ] **Step 1: Write the failing (network-free) test**

Only the pieces testable without a live Daytona are asserted here; live behavior is covered by the `sandbox_daytona` dogfood.

```ruby
require "test_helper"

class DaytonaClientTest < Minitest::Test
  def test_missing_api_key_fails_fast
    error = assert_raises(Rbrun::Sandbox::Daytona::Client::Error) do
      Rbrun::Sandbox::Daytona::Client.new(api_key: "", api_url: "https://api.example")
    end
    assert_match(/credentials missing/i, error.message)
  end

  def test_builds_an_async_http_faraday_connection
    client = Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "https://api.example")
    conn = client.send(:conn)
    assert_instance_of Faraday::Adapter::AsyncHttp, conn.builder.adapter
    assert_equal "Bearer k", conn.headers["Authorization"]
  end

  def test_snapshot_ref_is_content_addressed_by_the_dockerfile
    default_client = Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "u")
    custom_client  = Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "u",
                                                         dockerfile: "FROM alpine\n", snapshot_name: "mine")
    # a host-injected Dockerfile changes the snapshot tag; same input ⇒ same tag (reuse).
    assert_match(%r{\Arbrun-sandbox:[0-9a-f]{16}\z}, default_client.snapshot_ref)
    assert_match(%r{\Amine:[0-9a-f]{16}\z}, custom_client.snapshot_ref)
    refute_equal default_client.snapshot_ref, custom_client.snapshot_ref
    assert_equal custom_client.snapshot_ref,
                 Rbrun::Sandbox::Daytona::Client.new(api_key: "k", api_url: "u",
                                                     dockerfile: "FROM alpine\n", snapshot_name: "mine").snapshot_ref
  end
end
```

- [ ] **Step 2: Run — verify it fails**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/daytona_client_test.rb)`
Expected: FAIL (`Rbrun::Sandbox::Daytona::Client` undefined).

- [ ] **Step 3: Write the Daytona namespace file**

`gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb` (the adapter class body is added in Task 6; for now just wire the namespace + client require):

```ruby
# frozen_string_literal: true

require "rbrun/sandbox/daytona/client"

module Rbrun
  module Sandbox
    # Daytona-backed sandbox. The adapter (contract surface) is defined in Task 6; the wire lives in
    # Daytona::Client.
    class Daytona
    end
  end
end
```

> Note: `class Daytona` and `module Daytona` would conflict. Define `Daytona` as a **class** here (the adapter), and put the client under it as `Daytona::Client`. So `client.rb` must open `class Daytona; class Client`. Adjust the require order: `daytona.rb` opens `class Daytona`, then requires `daytona/client`. Rewrite `daytona.rb` as:

```ruby
# frozen_string_literal: true

module Rbrun
  module Sandbox
    class Daytona
      # adapter methods added in Task 6
    end
  end
end

require "rbrun/sandbox/daytona/client"
```

- [ ] **Step 4: Build the client**

`gems/rbrun-sandbox/lib/rbrun/sandbox/daytona/client.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "digest"
require "cgi"
require "faraday"
require "faraday/multipart"
require "async"
require "async/http/faraday"
require "async/http/internet"

module Rbrun
  module Sandbox
    class Daytona
      # The Daytona API, and nothing else — sandboxes, and the files and commands inside them. It
      # knows nothing about sessions/agents/turns; Rbrun::Sandbox::Daytona (the adapter) is one box's
      # contract, this is the wire.
      #
      # FARADAY ON ASYNC-HTTP, and NOT the official `daytona` gem: that gem's Typhoeus → libcurl
      # transport is not fork-safe, and Falcon forks its workers — the first call inside a forked
      # worker deadlocks at 0% CPU forever. Faraday on async-http is pure Ruby and fiber-scheduler
      # friendly. CONSTRUCTED FROM EXPLICIT CREDENTIALS, never the environment.
      class Client
        class Error < StandardError; end

        TOOLBOX = "https://proxy.app.daytona.io/toolbox"
        AUTO_STOP_MINUTES = 5
        START_TIMEOUT = 90

        # Snapshot defaults — all overridable via config. The agent box is a SELF-BUILT Daytona
        # snapshot, built server-side from a Dockerfile STRING (POST /snapshots), content-addressed by
        # the Dockerfile digest so an unchanged image is reused and any change builds a fresh one.
        # Resources bake ON the snapshot (a snapshot-backed sandbox can't override cpu/memory/disk).
        DEFAULT_SNAPSHOT_NAME  = "rbrun-sandbox"
        DEFAULT_CPU    = 2
        DEFAULT_MEMORY = 4 # GiB
        DEFAULT_DISK   = 3 # GiB
        SNAPSHOT_BUILD_TIMEOUT = 900
        SNAPSHOT_POLL_INTERVAL = 5

        # A minimal base for the agent runner: bun (stages + runs client.ts), a shell, git, and a
        # `daytona` user owning /home/daytona/workspace (the box's working root). Hosts that need more
        # (python, Office readers, custom tooling) inject their own via config[:dockerfile].
        DEFAULT_DOCKERFILE = <<~DOCKER
          FROM oven/bun:1-debian
          RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \\
            && useradd -m daytona \\
            && mkdir -p /home/daytona/workspace && chown -R daytona:daytona /home/daytona \\
            && apt-get clean && rm -rf /var/lib/apt/lists/*
          USER daytona
          WORKDIR /home/daytona/workspace
        DOCKER

        attr_reader :api_key

        def initialize(api_key:, api_url:, dockerfile: nil, snapshot_name: nil, cpu: nil, memory: nil, disk: nil)
          @api_key       = api_key
          @api_url       = api_url
          @dockerfile    = dockerfile    || DEFAULT_DOCKERFILE
          @snapshot_name = snapshot_name || DEFAULT_SNAPSHOT_NAME
          @cpu           = cpu    || DEFAULT_CPU
          @memory        = memory || DEFAULT_MEMORY
          @disk          = disk   || DEFAULT_DISK
          @ensured       = {}
          raise Error, "daytona credentials missing (config.api_key)" if @api_key.nil? || @api_key.empty?
        end

        # The box for these labels, up and reachable. LABELS, NOT AN ID — we store nothing; the label
        # is the address. Nothing to go stale, so nothing to heal.
        def find_or_create(labels)
          box = find_by_labels(labels) || create_sandbox(labels)
          return box if box["state"].to_s == "started"

          await_started(box["id"])
        end

        # ── snapshot (the box's image, built server-side from config[:dockerfile]) ──────────────
        # Content-addressed tag: a digest of the Dockerfile, so an unchanged image is reused and any
        # change builds a fresh one.
        def snapshot_ref = "#{@snapshot_name}:#{Digest::SHA256.hexdigest(@dockerfile)[0, 16]}"

        # The snapshot every sandbox starts from — built once, lazily, by Daytona from our Dockerfile.
        # Absent (404) → create it (Daytona builds server-side) and wait until active; present → reuse.
        # Memoized per Dockerfile digest.
        def ensure_snapshot
          name = snapshot_ref
          @ensured[name] ||= begin
            create_snapshot(name) if snapshot_state(name).nil?
            await_snapshot_active(name) unless snapshot_state(name) == "active"
            name
          end
        end

        # POST /snapshots with the Dockerfile CONTENT — Daytona builds the image itself, no registry.
        # 409 = a concurrent creator won; the wait in ensure_snapshot still applies.
        def create_snapshot(name)
          post("#{@api_url}/snapshots", body: {
            "name" => name,
            "buildInfo" => { "dockerfileContent" => @dockerfile },
            "cpu" => @cpu, "memory" => @memory, "disk" => @disk
          })
        rescue Error => e
          raise unless e.message.include?("409")
        end

        # The snapshot's state ("active"/"error"/"build_failed"/…), or nil when it doesn't exist (404).
        def snapshot_state(name = snapshot_ref)
          r = conn.get("#{@api_url}/snapshots/#{CGI.escape(name)}")
          return nil if r.status == 404

          ok!(r).body["state"]
        end

        def await_snapshot_active(name)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SNAPSHOT_BUILD_TIMEOUT
          loop do
            state = snapshot_state(name)
            return if state == "active"
            raise Error, "snapshot #{name} entered #{state}" if %w[error build_failed].include?(state)
            raise Error, "snapshot #{name} not active in #{SNAPSHOT_BUILD_TIMEOUT}s (#{state})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep SNAPSHOT_POLL_INTERVAL
          end
        end

        # The box these labels name, or nil. The label index is eventually consistent and lies, so
        # the list DISCOVERS a candidate and `get` (which 404s the instant a box is gone) decides
        # whether it is real. Oldest first, so every later turn agrees which box is the conversation's.
        def find_by_labels(labels)
          body = get("#{@api_url}/sandbox", "labels" => labels.transform_values(&:to_s).to_json)
          items = body.is_a?(Hash) ? body["items"] : body

          candidate =
            Array(items)
              .reject { |s| %w[destroyed destroying error].include?(s["state"].to_s) }
              .min_by { |s| s["createdAt"].to_s }
          return nil unless candidate

          confirm(candidate["id"])
        end

        def await_started(id)
          request_start(id)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + START_TIMEOUT
          loop do
            box = confirm(id) or raise Error, "sandbox #{id} vanished while starting"
            return box if box["state"].to_s == "started"

            request_start(id) if box["state"].to_s == "stopped"
            raise Error, "sandbox #{id} stuck at #{box["state"]}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 1
          end
        end

        def request_start(id)
          post("#{@api_url}/sandbox/#{id}/start")
        rescue Error => e
          raise unless e.message.include?("409")
        end

        def destroy(id) = request(:delete, "#{@api_url}/sandbox/#{id}", params: { "force" => "true" })

        # ── inside the box ─────────────────────────────────────────────
        def exec(id, command, timeout: 60)
          post("#{TOOLBOX}/#{id}/process/execute", body: { "command" => command, "timeout" => timeout }, timeout: timeout + 15)
        end

        def download(id, path) = request(:get, "#{TOOLBOX}/#{id}/files/download", params: { "path" => path }).body.to_s

        # ── process sessions ───────────────────────────────────────────
        def create_session(id, session_id)
          post("#{TOOLBOX}/#{id}/process/session", body: { "sessionId" => session_id })
        end

        def session_exec(id, session_id, command)
          body = post("#{TOOLBOX}/#{id}/process/session/#{session_id}/exec",
                      body: { "command" => command, "runAsync" => true }, timeout: 30)
          body.is_a?(Hash) ? (body["cmdId"] || body["commandId"] || body["id"]) : body
        end

        def session_input(id, session_id, command_id, data)
          post("#{TOOLBOX}/#{id}/process/session/#{session_id}/command/#{command_id}/input", body: { "data" => data })
        end

        def session_command(id, session_id, command_id)
          get("#{TOOLBOX}/#{id}/process/session/#{session_id}/command/#{command_id}")
        end

        # FOLLOW the command's output live. RAW async-http, not Faraday: the Faraday async-http adapter
        # buffers the whole body, so its on_data never fires until the stream closes — a deadlock for a
        # follow that only closes on command exit. `skip` bytes are dropped first (resume offset).
        # Returns total bytes seen; blocks until the stream ends or the block returns truthy.
        def session_logs_follow(id, session_id, command_id, skip: 0, timeout: nil)
          url = "#{TOOLBOX}/#{id}/process/session/#{session_id}/command/#{command_id}/logs?follow=true"
          seen = 0
          Sync do |task|
            internet = Async::HTTP::Internet.new
            read = lambda do
              response = internet.get(url, [ [ "authorization", "Bearer #{@api_key}" ] ])
              while (chunk = response.body&.read)
                bytes = chunk.to_s
                prev = seen
                seen += bytes.bytesize
                if skip.positive? && seen <= skip
                  next
                elsif skip.positive? && prev < skip
                  bytes = bytes.byteslice(skip - prev..) || ""
                end
                next if bytes.empty?

                break if yield(bytes)
              end
            ensure
              response&.close
            end
            begin
              timeout ? task.with_timeout(timeout) { read.call } : read.call
            ensure
              internet&.close
            end
          end
          seen
        end

        def create_folder(id, path, mode = "755")
          request(:post, "#{TOOLBOX}/#{id}/files/folder", params: { "path" => path, "mode" => mode })
        end

        # `source` is a local path or an IO. Multipart, field name `file`, path as a query param.
        def upload(id, path, source)
          io = source.respond_to?(:read) ? source : File.open(source, "rb")
          part = Faraday::Multipart::FilePart.new(io, "application/octet-stream", File.basename(path))
          request(
            :post,
            "#{TOOLBOX}/#{id}/files/upload",
            params: { "path" => path },
            body: { "file" => part },
            timeout: 120
          )
        ensure
          io.close if io && !source.respond_to?(:read)
        end

        private

        def confirm(id)
          r = conn.get("#{@api_url}/sandbox/#{id}")
          return nil if r.status == 404

          ok!(r).body
        end

        def create_sandbox(labels)
          post(
            "#{@api_url}/sandbox",
            body: {
              "labels" => labels.transform_values(&:to_s),
              "autoStopInterval" => AUTO_STOP_MINUTES,
              # Start from the self-built snapshot (config[:dockerfile]), built server-side on first
              # use. Resources are baked on the snapshot — the API refuses cpu/memory/disk here.
              "snapshot" => ensure_snapshot
            },
            timeout: 120
          )
        end

        def get(url, params = {}) = request(:get, url, params: params).body

        def post(url, body: nil, params: {}, timeout: 60) = request(:post, url, body: body, params: params, timeout: timeout).body

        def request(method, url, params: {}, body: nil, timeout: 60)
          response = conn.public_send(method, url) do |req|
            req.options.timeout = timeout
            req.params.update(params)
            next if body.nil?

            if body.is_a?(Hash) && body.values.any? { |v| v.is_a?(Faraday::Multipart::FilePart) }
              req.body = body
            else
              req.headers["Content-Type"] = "application/json"
              req.body = body.to_json
            end
          end
          ok!(response)
        end

        def ok!(response)
          return response if response.success?

          raise Error, "#{response.env.method.to_s.upcase} #{response.env.url.path} → #{response.status}: #{response.body.to_s[0, 200]}"
        end

        def conn
          @conn ||= Faraday.new do |f|
            f.request :multipart
            f.response :json, content_type: /\bjson/
            f.headers["Authorization"] = "Bearer #{@api_key}"
            f.options.open_timeout = 15
            f.adapter :async_http
          end
        end
      end
    end
  end
end
```

- [ ] **Step 5: Run — verify it passes**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/daytona_client_test.rb)`
Expected: PASS (2 runs, 0 failures). If `Faraday::Adapter::AsyncHttp` is not the exact constant, adjust the assertion to `conn.adapter == Faraday::Adapter::AsyncHttp` per the installed `async-http-faraday` version.

- [ ] **Step 6: Commit**

```bash
git add gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb gems/rbrun-sandbox/lib/rbrun/sandbox/daytona/client.rb gems/rbrun-sandbox/test/rbrun/sandbox/daytona_client_test.rb
git commit -m "feat(sandbox): Daytona::Client — Faraday+async-http client (config-injected creds)"
```

---

### Task 6: `Daytona` adapter — the contract over the client

**Files:**

- Modify: `gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb` (fill the adapter class)
- Test: `gems/rbrun-sandbox/test/rbrun/sandbox/daytona_adapter_test.rb`

**Interfaces:**

- Consumes: `Daytona::Client` (Task 5), `ExecResult`, `FileUpload`.
- Produces: `Rbrun::Sandbox::Daytona.new(config:, labels:, client: nil)` implementing the full normalized contract, delegating to a memoized box id. `client:` is injectable for tests.

- [ ] **Step 1: Write the failing test (with a fake client — no network)**

```ruby
require "test_helper"

class DaytonaAdapterTest < Minitest::Test
  # A hand fake standing in for Daytona::Client, recording calls and returning canned wire shapes.
  class FakeClient
    attr_reader :calls

    def initialize = @calls = []
    def find_or_create(_labels) = { "id" => "box-1", "state" => "started" }
    def exec(_id, command, timeout: 60)
      @calls << [ :exec, command, timeout ]
      command.include?("boom") ? { "exitCode" => 2, "result" => "nope" } : { "exitCode" => 0, "result" => "ok\n" }
    end
    def download(_id, path) = "contents-of-#{path}"
    def create_folder(_id, path, _mode = "755") = @calls << [ :create_folder, path ]
    def upload(_id, path, _source) = @calls << [ :upload, path ]
    def destroy(_id) = @calls << [ :destroy ]
    def create_session(_id, sid) = @calls << [ :create_session, sid ]
    def session_exec(_id, sid, command) = "cmd-9"
    def session_input(_id, _sid, _cid, data) = @calls << [ :session_input, data ]
    def session_command(_id, _sid, _cid) = { "exitCode" => 0 }
  end

  def build(client = FakeClient.new)
    Rbrun::Sandbox::Daytona.new(config: { api_key: "k", api_url: "u" }, labels: { session: 1 }, client: client)
  end

  def test_config_fails_fast_without_api_key
    assert_raises(Rbrun::Sandbox::Error) do
      Rbrun::Sandbox::Daytona.new(config: { api_url: "u" }, labels: {})
    end
  end

  def test_exec_normalizes_to_exec_result
    result = build.exec("echo ok")
    assert_instance_of Rbrun::Sandbox::ExecResult, result
    assert result.success?
    assert_equal "ok\n", result.stdout
  end

  def test_exec_bang_raises_on_nonzero
    assert_raises(Rbrun::Sandbox::Error) { build.exec!("boom") }
  end

  def test_exist_uses_exit_code
    adapter = build
    assert adapter.exist?("/some/path")            # exec exit 0 → true
    refute adapter.exist?("/boom/path")            # exec exit 2 → false
  end

  def test_write_creates_folder_then_uploads
    client = FakeClient.new
    build(client).write("/w/dir/a.txt", "hello")
    assert_includes client.calls.map(&:first), :create_folder
    assert_includes client.calls.map(&:first), :upload
  end

  def test_session_delegates_with_box_id
    client = FakeClient.new
    adapter = build(client)
    adapter.session_create("s1")
    assert_equal "cmd-9", adapter.session_exec("s1", "run")
    adapter.session_input("s1", "cmd-9", "data")
    assert_equal 0, adapter.session_command("s1", "cmd-9")["exitCode"]
    assert_includes client.calls, [ :create_session, "s1" ]
  end

  def test_destroy_resets_the_box
    client = FakeClient.new
    build(client).destroy!
    assert_includes client.calls, [ :destroy ]
  end
end
```

- [ ] **Step 2: Run — verify it fails**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/daytona_adapter_test.rb)`
Expected: FAIL (adapter body is empty).

- [ ] **Step 3: Implement the adapter (the normalized `Workspace` contract)**

Replace `gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb` with:

```ruby
# frozen_string_literal: true

require "shellwords"
require "tempfile"

module Rbrun
  module Sandbox
    # ONE box's contract, Daytona-backed. Found by LABEL, never a stored id (see Client#find_or_create).
    # A path is a path inside this sandbox, always. Normalizes the wire's `{ "exitCode", "result" }`
    # into ExecResult so callers speak one contract across adapters.
    class Daytona
      ROOT = "/home/daytona"
      WORKSPACE = File.join(ROOT, "workspace")

      def initialize(config: {}, labels: {}, client: nil)
        @labels = labels
        @client = client || Client.new(
          api_key:       config[:api_key],
          api_url:       config[:api_url],
          dockerfile:    config[:dockerfile],
          snapshot_name: config[:snapshot_name],
          cpu:           config[:cpu],
          memory:        config[:memory],
          disk:          config[:disk]
        )
      rescue Client::Error => e
        raise Error, e.message
      end

      def id = sandbox["id"]

      def workspace = WORKSPACE

      def exec(command, timeout: 60)
        raw = @client.exec(id, command, timeout: timeout)
        ExecResult.new(exit_code: raw["exitCode"].to_i, stdout: raw["result"].to_s, stderr: "")
      end

      def exec!(command, timeout: 60)
        result = exec(command, timeout: timeout)
        return result if result.success?

        raise Error, "#{command.inspect} exited #{result.exit_code}: #{result.stdout.to_s.lines.last(5).join}"
      end

      def write(remote_path, content)
        @client.create_folder(id, File.dirname(remote_path))
        Tempfile.create("rbrun-upload") do |tmp|
          tmp.binmode
          tmp.write(content.to_s)
          tmp.flush
          @client.upload(id, remote_path, tmp.path)
        end
      end

      def read(remote_path) = @client.download(id, remote_path)

      def exist?(remote_path) = exec("test -e #{Shellwords.escape(remote_path)}").success?

      def create_folder(path, mode = "755") = @client.create_folder(id, path, mode)

      def upload(files)
        files.map { |f| File.dirname(f.destination) }.uniq.each { |d| @client.create_folder(id, d) }
        files.each { |f| @client.upload(id, f.destination, f.source) }
      end

      def glob(dir)
        exec("cd #{Shellwords.escape(dir)} && find . -type f | sed 's|^\\./||' | sort")
          .stdout.to_s.lines.map(&:strip).reject(&:empty?)
      end

      def destroy!
        @client.destroy(id)
        @sandbox = nil
      end

      # ── process sessions (delegate, injecting our own box id) ──────────
      def session_create(session_id) = @client.create_session(id, session_id)
      def session_exec(session_id, command) = @client.session_exec(id, session_id, command)
      def session_input(session_id, cmd_id, data) = @client.session_input(id, session_id, cmd_id, data)
      def session_command(session_id, cmd_id) = @client.session_command(id, session_id, cmd_id)

      def session_logs_follow(session_id, cmd_id, skip: 0, timeout: nil, &block)
        @client.session_logs_follow(id, session_id, cmd_id, skip: skip, timeout: timeout, &block)
      end

      private

      # Resolved once per instance (the caller memoizes the adapter), so one turn is one lookup.
      def sandbox = @sandbox ||= @client.find_or_create(@labels)
    end
  end
end

require "rbrun/sandbox/daytona/client"
```

- [ ] **Step 4: Run — verify it passes**

Run: `(cd gems/rbrun-sandbox && bundle exec ruby -Ilib -Itest test/rbrun/sandbox/daytona_adapter_test.rb)`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 5: Run the whole gem suite**

Run: `(cd gems/rbrun-sandbox && bundle exec rake test)`
Expected: all files green (dispatch, line_buffer, local, local_session, daytona_client, daytona_adapter).

- [ ] **Step 6: Commit**

```bash
git add gems/rbrun-sandbox/lib/rbrun/sandbox/daytona.rb gems/rbrun-sandbox/test/rbrun/sandbox/daytona_adapter_test.rb
git commit -m "feat(sandbox): Daytona adapter — normalized contract over the client"
```

---

### Task 7: Dogfood scenarios — `sandbox_local` (offline) + `sandbox_daytona` (live)

**Files:**

- Create: `lib/tasks/rbrun/dogfood/sandbox_local.rake`, `lib/tasks/rbrun/dogfood/sandbox_daytona.rake`

**Interfaces:**

- Consumes: `Rbrun::Sandbox` (the gem), `Rbrun::Dogfood` (Phase 1 spine).

- [ ] **Step 1: Write the local dogfood (offline, no Rails, no creds)**

`lib/tasks/rbrun/dogfood/sandbox_local.rake`:

```ruby
# frozen_string_literal: true

require "rbrun/sandbox"
require_relative "support"

# Phase 2 dogfood — the LOCAL sandbox, for real (real processes, real files, offline). Exercises the
# full contract end to end: create → upload → exec → glob → a streaming process session → read → destroy.
#
#   bin/rails app:dogfood:sandbox_local

namespace :dogfood do
  desc "Phase 2: the local sandbox runs the full exec/file/session contract for real (offline)"
  task :sandbox_local do
    dog = Rbrun::Dogfood
    box = Rbrun::Sandbox.new(provider: :local, config: {}, labels: { dogfood: "local" })

    dog.header "files"
    box.write("uploads/hello.txt", "bonjour")
    dog.ok "wrote + read back a file", box.read("uploads/hello.txt") == "bonjour"
    dog.ok "exist? is true for a written path", box.exist?("uploads/hello.txt")
    box.write("sub/nested.txt", "x")
    dog.ok "glob lists files relative + sorted", box.glob(".") == [ "sub/nested.txt", "uploads/hello.txt" ]

    dog.header "exec"
    result = box.exec("echo streamed")
    dog.ok "exec returns a successful ExecResult", result.success? && result.stdout == "streamed\n"

    dog.header "process session (streamed stdin→stdout)"
    box.session_create("s")
    cmd = box.session_exec("s", "cat") # echoes stdin, exits on stdin close
    box.session_input("s", cmd, "ping\n")
    seen = String.new
    bytes = box.session_logs_follow("s", cmd, skip: 0, timeout: 5) { |c| seen << c; seen.include?("ping") }
    dog.ok "session streamed our stdin back on stdout", seen.include?("ping")
    dog.ok "follow reported a positive byte offset", bytes.positive?

    dog.header "teardown"
    root = box.workspace
    box.destroy!
    dog.ok "destroy! removed the box directory", !File.exist?(root)
  end
end
```

- [ ] **Step 2: Run the local dogfood**

Run: `bin/rails app:dogfood:sandbox_local`
Expected: all ✓ across files / exec / process session / teardown.

- [ ] **Step 3: Write the daytona dogfood (live; reads creds from the dummy app's credentials)**

`lib/tasks/rbrun/dogfood/sandbox_daytona.rake`:

```ruby
# frozen_string_literal: true

require "rbrun/sandbox"
require_relative "support"

# Phase 2 dogfood — the DAYTONA sandbox, for real (live cloud box). Same contract as sandbox_local,
# against a real Daytona sandbox. Credentials come from the dummy app's Rails credentials
# (daytona.api_key / daytona.api_url) — a secret store, not a variable: dogfood is never parameterized.
# Needs :environment to load credentials.
#
#   bin/rails app:dogfood:sandbox_daytona

namespace :dogfood do
  desc "Phase 2: the daytona sandbox runs the full contract for real (live cloud box)"
  task sandbox_daytona: :environment do
    dog = Rbrun::Dogfood
    creds = Rails.application.credentials.dig(:daytona) || {}
    if creds[:api_key].to_s.empty?
      abort "No daytona credentials. Set daytona.api_key / daytona.api_url via `bin/rails credentials:edit` in test/dummy."
    end

    # No dockerfile here → the client's DEFAULT_DOCKERFILE (bun+shell) builds the snapshot. A host
    # that needs more tooling passes config[:dockerfile] with its own image.
    box = Rbrun::Sandbox.new(
      provider: :daytona,
      config: { api_key: creds[:api_key], api_url: creds[:api_url] },
      labels: { dogfood: "daytona" }
    )

    begin
      dog.header "box up"
      dog.ok "resolved a started box (find_or_create)", !box.id.to_s.empty?

      dog.header "files"
      box.write(File.join(box.workspace, "hello.txt"), "bonjour")
      dog.ok "wrote + read back a file", box.read(File.join(box.workspace, "hello.txt")) == "bonjour"
      dog.ok "exist? true for the written path", box.exist?(File.join(box.workspace, "hello.txt"))

      dog.header "exec"
      dog.ok "exec echo → ExecResult ok", box.exec("echo streamed").stdout == "streamed\n"

      dog.header "process session"
      box.session_create("s")
      cmd = box.session_exec("s", "printf 'AAAAABBBBB'")
      seen = String.new
      box.session_logs_follow("s", cmd, skip: 0, timeout: 30) { |c| seen << c; false }
      dog.ok "session streamed the command output", seen.include?("AAAAABBBBB")
    ensure
      box.destroy!
      dog.info "teardown", "box destroyed"
    end
  end
end
```

- [ ] **Step 4: Run the daytona dogfood** (requires `test/dummy` credentials with `daytona.api_key`/`api_url`)

Run: `bin/rails app:dogfood:sandbox_daytona`
Expected (with creds): all ✓ (box up / files / exec / process session), then `teardown: box destroyed`. Without creds: a clean `abort` message telling you to set them — not a failure of the adapter.

- [ ] **Step 5: Run the whole gem suite once more + commit**

```bash
(cd gems/rbrun-sandbox && bundle exec rake test)
git add lib/tasks/rbrun/dogfood/sandbox_local.rake lib/tasks/rbrun/dogfood/sandbox_daytona.rake
git commit -m "feat(dogfood): sandbox_local (offline) + sandbox_daytona (live) — Phase 2 acceptance gates"
```

---

## Self-Review

**1. Spec coverage (Phase 2 contract):**

- Normalized contract (`exec/exec_stream/upload/read/exist?/glob/create_folder/session_*/destroy!` + `ExecResult` + `FileUpload`) → Tasks 1 (values), 3–4 (local), 6 (daytona). ✓
- `sandbox_provider` family via `Rbrun::Sandbox.new(provider:)` constant lookup, no registration → Task 1 dispatcher. ✓
- `local` adapter (real host executor) → Tasks 3–4. ✓
- `daytona` adapter (Faraday+async-http, label-addressed, raw async-http `session_logs_follow`) → Tasks 5–6. ✓
- HTTP invariant honored (Faraday+async_http adapter; raw async-http carve-out) → Task 5. ✓
- Deliverables: gem + unit tests (pure logic + local integration) → Tasks 1–6; two hardcoded dogfoods → Task 7. ✓

**2. Placeholder scan:** The Task 1 Step 6 stubs for `local.rb`/`daytona.rb`/`line_buffer.rb` are explicitly temporary and each is fully replaced in its own task (2, 3–4, 5–6). No "TODO"/"handle edge cases"/"similar to". Every code block is complete.

**3. Type/name consistency:** `Rbrun::Sandbox.new(provider:, config:, labels:)`; adapters expose the identical contract method set; `ExecResult(exit_code, stdout, stderr)` + `#success?`; `FileUpload(source, destination)`; `Daytona::Client.new(api_key:, api_url:)`; session methods take `(session_id, …)` on adapters and `(id, session_id, …)` on the client. The `Daytona` **class** (not module) holds `Client` as a nested class — namespacing is consistent between `daytona.rb` and `daytona/client.rb` (both open `class Daytona`).

**Risk areas (validated by dogfood, not just unit tests):** local process-session streaming (Task 4) and every live Daytona path (Tasks 5–6) — the `sandbox_local` and `sandbox_daytona` gates in Task 7 exercise them for real, which is exactly what the stubbed unit tests structurally cannot.

**Note carried to Phase 3:** the runtime's `Rbrun.sandbox` engine wrapper (`Rbrun.build(Rbrun::Sandbox, Rbrun.config.sandbox_provider, provider:)`) and the Runner consume this contract — `ExecResult#exit_code`/`#stdout` and the `session_*` surface are the seam.
