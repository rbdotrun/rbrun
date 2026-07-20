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
end
