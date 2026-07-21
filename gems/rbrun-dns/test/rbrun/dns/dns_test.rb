# frozen_string_literal: true

require "test_helper"

class DnsTest < Minitest::Test
  def test_resolves_the_adapter_by_constant_lookup
    dns = Rbrun::Dns.new(provider: :cloudflare, config: { api_token: "t", zone_id: "z" })
    assert_instance_of Rbrun::Dns::Cloudflare, dns
  end

  def test_unknown_provider_fails_loud
    error = assert_raises(Rbrun::Dns::Error) { Rbrun::Dns.new(provider: :route53, config: {}) }
    assert_match(/unknown dns provider :route53/, error.message)
  end

  def test_record_is_a_value_object
    r = Rbrun::Dns::Record.new(id: "1", name: "a.rb.run", type: "CNAME", content: "x", proxied: true)
    assert_equal "a.rb.run", r.name
    assert r.proxied
  end

  # Every adapter must respect the Rbrun::Dns::Base interface.
  def test_cloudflare_implements_the_base_interface
    assert_operator Rbrun::Dns::Cloudflare, :<, Rbrun::Dns::Base
  end

  def test_base_methods_are_unimplemented_until_an_adapter_overrides_them
    base = Rbrun::Dns::Base.new
    assert_raises(NotImplementedError) { base.find(name: "a.rb.run") }
    assert_raises(NotImplementedError) { base.list }
    assert_raises(NotImplementedError) { base.upsert(name: "a.rb.run", type: "A", content: "1.2.3.4") }
    assert_raises(NotImplementedError) { base.remove(name: "a.rb.run") }
  end
end
