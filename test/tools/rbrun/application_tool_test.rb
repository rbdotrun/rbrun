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

  class FormGate < Rbrun::ApplicationTool
    custom_approval! submit: :form_gate_response
    description "custom gate"
    parameter :form_spec, type: "object", required: true
    def name = "form_gate"
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
    session = rbrun_session(tenant: "acme")
    tool = Adder.in_session(session)
    assert_equal({ "data" => { "sum" => 5 } }, tool.execute(a: 2, b: 3))
  end

  test "custom_approval! implies a gate + custom card + submit route" do
    assert FormGate.needs_approval?, "custom_approval! is a gate"
    assert FormGate.custom_approval?
    assert_equal :form_gate_response, FormGate.approval_submit_route
  end

  test "a custom gate has a degrade execute (no computed result)" do
    assert_equal({ "data" => { "gated" => "form_gate_response" } }, FormGate.new.execute(form_spec: {}))
  end

  test "a plain needs_approval tool is not a custom approval" do
    assert Dangerous.needs_approval?
    refute Dangerous.custom_approval?
    assert_nil Dangerous.approval_submit_route
  end

  test "manifest still reports needs_approval true for a custom gate" do
    assert_equal true, Rbrun::ApplicationTool.manifest_entry(FormGate)["needs_approval"]
  end
end
