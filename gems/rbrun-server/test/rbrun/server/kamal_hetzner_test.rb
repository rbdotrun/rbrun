# frozen_string_literal: true

require "test_helper"

class KamalHetznerTest < Minitest::Test
  API = "https://api.hetzner.cloud/v1"
  CFG = { hcloud_token: "tok", registry: { server: "docker.io", username: "u", password: "pw" } }.freeze
  PUB = "ssh-ed25519 AAAAtest"
  PRIV = "-----BEGIN OPENSSH PRIVATE KEY-----\nx\n-----END OPENSSH PRIVATE KEY-----\n"

  def adapter = Rbrun::Server::KamalHetzner.new(config: CFG, poll_interval: 0, poll_attempts: 3)

  def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  def test_missing_token_fails_fast
    error = assert_raises(Rbrun::Server::Error) { Rbrun::Server::KamalHetzner.new(config: CFG.merge(hcloud_token: "")) }
    assert_match(/hcloud_token/, error.message)
  end

  def test_create_server_is_idempotent_returns_existing
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-1" })
      .to_return(json(servers: [ { id: 9, name: "w-1", status: "running",
        public_net: { ipv4: { ip: "5.6.7.8" } }, datacenter: { location: { name: "fsn1" } } } ]))

    node = adapter.create_server(name: "w-1", type: "cx23", region: "fsn1", image: "ubuntu-24.04", ssh_public_key: PUB)
    assert_equal "5.6.7.8", node.ip
    assert_equal "running", node.status
  end

  def test_create_server_uploads_the_given_key_then_posts_and_polls
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-2" }).to_return(json(servers: []))
    stub_request(:get, "#{API}/ssh_keys").with(query: { "name" => "w-2" }).to_return(json(ssh_keys: []))
    key_post = stub_request(:post, "#{API}/ssh_keys")
      .with(body: hash_including("name" => "w-2", "public_key" => PUB)).to_return(json(ssh_key: { id: 2, name: "w-2" }))
    stub_request(:post, "#{API}/servers")
      .to_return(json(server: { id: 10, name: "w-2", status: "initializing", public_net: { ipv4: { ip: nil } } }))
    stub_request(:get, "#{API}/servers/10")
      .to_return(json(server: { id: 10, name: "w-2", status: "running",
        public_net: { ipv4: { ip: "1.1.1.1" } }, datacenter: { location: { name: "fsn1" } } }))

    node = adapter.create_server(name: "w-2", type: "cx23", region: "fsn1", image: "ubuntu-24.04", ssh_public_key: PUB)
    assert_equal "1.1.1.1", node.ip
    assert_requested key_post
  end

  def test_create_server_rolls_over_to_another_location_on_placement_error
    stub_request(:get, "#{API}/servers").with(query: { "name" => "w-5" }).to_return(json(servers: []))
    stub_request(:get, "#{API}/ssh_keys").with(query: { "name" => "w-5" }).to_return(json(ssh_keys: [ { id: 1, name: "w-5" } ]))
    # first POST: fsn1 out of capacity (412 placement); second POST: succeeds
    stub_request(:post, "#{API}/servers")
      .to_return({ status: 412, body: { error: { message: "error during placement" } }.to_json, headers: { "Content-Type" => "application/json" } },
                 json(server: { id: 20, name: "w-5", status: "running",
                   public_net: { ipv4: { ip: "7.7.7.7" } }, datacenter: { location: { name: "nbg1" } } }))

    node = adapter.create_server(name: "w-5", type: "cx23", region: "fsn1", image: "ubuntu-24.04", ssh_public_key: PUB)
    assert_equal "7.7.7.7", node.ip
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

  def test_deploy_shells_kamal_with_registry_server_ip_and_ssh_key_file
    captured = {}
    adp = adapter
    adp.define_singleton_method(:run_kamal) do |argv, env:, chdir:|
      captured[:argv] = argv; captured[:env] = env; captured[:chdir] = chdir
      captured[:key] = File.read(env["KAMAL_SSH_KEY_FILE"]) # the key file exists for the command's duration
      [ "Deployed w-1", true ]
    end
    adp.define_singleton_method(:forget_host_key) { |ip| captured[:forgot] = ip } # don't touch real known_hosts

    result = adp.deploy(work_dir: "/work/w-1", host: "w1.rb.run", server_ip: "1.1.1.1", ssh_private_key: PRIV)
    assert result.ok
    assert_equal "/work/w-1", captured[:chdir]
    assert_includes captured[:argv], "deploy"
    assert_equal "pw", captured[:env]["KAMAL_REGISTRY_PASSWORD"]
    assert_equal "1.1.1.1", captured[:env]["KAMAL_SERVER_IP"]
    assert_equal "w1.rb.run", captured[:env]["KAMAL_HOST"]
    assert_equal PRIV, captured[:key]
    # Recycled-IP guard: the stale host key is forgotten before kamal SSHes in (else Net::SSH mismatch).
    assert_equal "1.1.1.1", captured[:forgot]
  end

  def test_app_logs_shells_kamal_app_logs
    captured = {}
    adp = adapter
    adp.define_singleton_method(:run_kamal) do |argv, env:, chdir:|
      captured[:argv] = argv; captured[:env] = env
      [ "line1\nline2", true ]
    end
    adp.define_singleton_method(:forget_host_key) { |ip| captured[:forgot] = ip } # don't touch real known_hosts

    out = adp.app_logs(work_dir: "/work/w-1", server_ip: "1.1.1.1", ssh_private_key: PRIV, tail: 50)
    assert_equal "line1\nline2", out
    assert_equal [ "app", "logs", "-n", "50" ], captured[:argv]
    assert_equal "1.1.1.1", captured[:env]["KAMAL_SERVER_IP"]
    assert captured[:env]["KAMAL_SSH_KEY_FILE"]
  end
end
