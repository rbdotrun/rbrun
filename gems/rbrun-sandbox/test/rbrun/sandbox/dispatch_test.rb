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
