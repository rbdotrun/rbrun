require "test_helper"
require "json"
require "tmpdir"
require "fileutils"

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
