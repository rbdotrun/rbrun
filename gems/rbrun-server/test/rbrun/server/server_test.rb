# frozen_string_literal: true

require "test_helper"

class ServerTest < Minitest::Test
  def test_unknown_provider_fails_loud
    error = assert_raises(Rbrun::Server::Error) { Rbrun::Server.new(provider: :aws, config: {}) }
    assert_match(/unknown server provider :aws/, error.message)
  end

  # Every adapter must respect the Rbrun::Server::Base interface.
  def test_base_methods_are_unimplemented_until_overridden
    base = Rbrun::Server::Base.new
    assert_raises(NotImplementedError) { base.create_server(name: "x", type: "cx23", region: "fsn1", image: "ubuntu-24.04") }
    assert_raises(NotImplementedError) { base.find_server(name: "x") }
    assert_raises(NotImplementedError) { base.list_servers }
    assert_raises(NotImplementedError) { base.destroy_server(name: "x") }
    assert_raises(NotImplementedError) { base.deploy(work_dir: "/tmp", host: "h", server_ip: "1.2.3.4") }
  end

  def test_node_and_deploy_result_are_value_objects
    n = Rbrun::Server::Node.new(id: 1, name: "x", ip: "1.2.3.4", status: "running", region: "fsn1")
    assert_equal "1.2.3.4", n.ip
    assert Rbrun::Server::DeployResult.new(ok: true, output: "done").ok
  end
end
