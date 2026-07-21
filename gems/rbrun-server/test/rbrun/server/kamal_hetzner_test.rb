# frozen_string_literal: true

require "test_helper"

class KamalHetznerTest < Minitest::Test
  API = "https://api.hetzner.cloud/v1"
  CFG = { hcloud_token: "tok", ssh_public_key: "ssh-rsa k", ssh_private_key: "priv",
          registry: { server: "docker.io", username: "u", password: "pw" } }.freeze

  def adapter = Rbrun::Server::KamalHetzner.new(config: CFG, poll_interval: 0, poll_attempts: 3)

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  def test_missing_token_fails_fast
    error = assert_raises(Rbrun::Server::Error) { Rbrun::Server::KamalHetzner.new(config: CFG.merge(hcloud_token: "")) }
    assert_match(/hcloud_token/, error.message)
  end

  def test_missing_public_key_fails_fast
    error = assert_raises(Rbrun::Server::Error) { Rbrun::Server::KamalHetzner.new(config: CFG.merge(ssh_public_key: "")) }
    assert_match(/ssh_public_key/, error.message)
  end

  def test_create_server_is_idempotent_returns_existing
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-1" })
      .to_return(json(servers: [ { id: 9, name: "w-1", status: "running",
        public_net: { ipv4: { ip: "5.6.7.8" } }, datacenter: { location: { name: "fsn1" } } } ]))

    node = adapter.create_server(name: "w-1", type: "cx23", region: "fsn1", image: "ubuntu-24.04")
    assert_equal "5.6.7.8", node.ip
    assert_equal "running", node.status
  end

  def test_create_server_posts_then_polls_until_running
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-2" }).to_return(json(servers: []))
    stub_request(:get, "#{API}/ssh_keys").with(query: { "name" => "rbrun" })
      .to_return(json(ssh_keys: [ { id: 1, name: "rbrun" } ]))
    stub_request(:post, "#{API}/servers")
      .to_return(json(server: { id: 10, name: "w-2", status: "initializing", public_net: { ipv4: { ip: nil } } }))
    stub_request(:get, "#{API}/servers/10")
      .to_return(json(server: { id: 10, name: "w-2", status: "initializing", public_net: { ipv4: { ip: nil } } }),
                 json(server: { id: 10, name: "w-2", status: "running",
                   public_net: { ipv4: { ip: "1.1.1.1" } }, datacenter: { location: { name: "fsn1" } } }))

    node = adapter.create_server(name: "w-2", type: "cx23", region: "fsn1", image: "ubuntu-24.04")
    assert_equal "1.1.1.1", node.ip
    assert_equal "running", node.status
  end

  def test_create_server_uploads_ssh_key_when_absent
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-3" }).to_return(json(servers: []))
    stub_request(:get, "#{API}/ssh_keys").with(query: { "name" => "rbrun" }).to_return(json(ssh_keys: []))
    key_post = stub_request(:post, "#{API}/ssh_keys").to_return(json(ssh_key: { id: 2, name: "rbrun" }))
    stub_request(:post, "#{API}/servers")
      .to_return(json(server: { id: 11, name: "w-3", status: "running",
        public_net: { ipv4: { ip: "2.2.2.2" } }, datacenter: { location: { name: "fsn1" } } }))

    node = adapter.create_server(name: "w-3", type: "cx23", region: "fsn1", image: "ubuntu-24.04")
    assert_equal "2.2.2.2", node.ip
    assert_requested key_post
  end

  def test_destroy_server_is_noop_when_absent
    stub_request(:get, "#{API}/servers").with(query: { "name" => "gone" }).to_return(json(servers: []))
    refute adapter.destroy_server(name: "gone")
  end

  def test_destroy_server_deletes_when_present
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-4" })
      .to_return(json(servers: [ { id: 12, name: "w-4", status: "running", public_net: { ipv4: { ip: "3.3.3.3" } } } ]))
    del = stub_request(:delete, "#{API}/servers/12").to_return(status: 200, body: "{}")
    assert adapter.destroy_server(name: "w-4")
    assert_requested del
  end
end
