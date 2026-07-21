# frozen_string_literal: true

require "test_helper"

class ServerConstructorTest < ActiveSupport::TestCase
  test "Rbrun.server builds the configured adapter" do
    Rbrun.configure do |c|
      c.server_provider = { default: :kamal_hetzner,
                            kamal_hetzner: { hcloud_token: "t", ssh_public_key: "ssh-rsa k", ssh_private_key: "p",
                                             registry: { server: "docker.io", username: "u", password: "pw" } } }
    end
    assert_instance_of Rbrun::Server::KamalHetzner, Rbrun.server
  end

  test "Rbrun.server surfaces a missing-config error fail-fast" do
    Rbrun.configure do |c|
      c.server_provider = { default: :kamal_hetzner, kamal_hetzner: { ssh_public_key: "k", ssh_private_key: "p" } }
    end
    assert_raises(Rbrun::Server::Error) { Rbrun.server }
  end
end
