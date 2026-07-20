# frozen_string_literal: true

require "test_helper"

class CloudflareTest < Minitest::Test
  ZONE = "zone123"
  BASE = "https://api.cloudflare.com/client/v4"

  def build = Rbrun::Dns::Cloudflare.new(config: { api_token: "tok", zone_id: ZONE })

  def records_url = "#{BASE}/zones/#{ZONE}/dns_records"

  def test_fails_fast_without_credentials
    assert_raises(Rbrun::Dns::Error) { Rbrun::Dns::Cloudflare.new(config: { zone_id: ZONE }) }
    assert_raises(Rbrun::Dns::Error) { Rbrun::Dns::Cloudflare.new(config: { api_token: "t" }) }
  end

  def test_find_returns_a_record_or_nil
    stub_request(:get, records_url).with(query: { "name" => "a.rb.run", "type" => "CNAME" })
      .to_return_json(body: { success: true, result: [ { id: "r1", name: "a.rb.run", type: "CNAME", content: "x.cfargotunnel.com", proxied: true } ] })
    r = build.find(name: "a.rb.run", type: "CNAME")
    assert_equal "r1", r.id
    assert r.proxied

    stub_request(:get, records_url).with(query: { "name" => "missing.rb.run" })
      .to_return_json(body: { success: true, result: [] })
    assert_nil build.find(name: "missing.rb.run")
  end

  def test_upsert_CREATES_when_absent
    stub_request(:get, records_url).with(query: hash_including("name" => "*.rb.run"))
      .to_return_json(body: { success: true, result: [] })
    create = stub_request(:post, records_url)
      .with(body: { type: "CNAME", name: "*.rb.run", content: "t.cfargotunnel.com", proxied: true })
      .to_return_json(body: { success: true, result: { id: "new1", name: "*.rb.run", type: "CNAME", content: "t.cfargotunnel.com", proxied: true } })

    r = build.upsert(name: "*.rb.run", type: "CNAME", content: "t.cfargotunnel.com", proxied: true)
    assert_equal "new1", r.id
    assert_requested create
  end

  def test_upsert_PATCHES_when_present_and_never_duplicates
    stub_request(:get, records_url).with(query: hash_including("name" => "*.rb.run"))
      .to_return_json(body: { success: true, result: [ { id: "r9", name: "*.rb.run", type: "CNAME", content: "old", proxied: true } ] })
    patch = stub_request(:patch, "#{records_url}/r9")
      .to_return_json(body: { success: true, result: { id: "r9", name: "*.rb.run", type: "CNAME", content: "t.cfargotunnel.com", proxied: true } })
    post = stub_request(:post, records_url)

    r = build.upsert(name: "*.rb.run", type: "CNAME", content: "t.cfargotunnel.com", proxied: true)
    assert_equal "r9", r.id
    assert_requested patch
    assert_not_requested post
  end

  def test_remove_deletes_when_present
    stub_request(:get, records_url).with(query: hash_including("name" => "*.rb.run"))
      .to_return_json(body: { success: true, result: [ { id: "r5", name: "*.rb.run", type: "CNAME", content: "x", proxied: true } ] })
    del = stub_request(:delete, "#{records_url}/r5").to_return_json(body: { success: true, result: { id: "r5" } })

    assert build.remove(name: "*.rb.run", type: "CNAME")
    assert_requested del
  end

  def test_remove_is_a_noop_when_absent
    stub_request(:get, records_url).with(query: hash_including("name" => "gone.rb.run"))
      .to_return_json(body: { success: true, result: [] })
    refute build.remove(name: "gone.rb.run")
  end

  def test_list_pages_the_whole_zone_and_filters_by_suffix
    stub_request(:get, records_url).with(query: hash_including("page" => "1", "per_page" => "100"))
      .to_return_json(body: { success: true, result_info: { total_pages: 2 }, result: [
        { id: "p1", name: "aaa-preview.rb.run", type: "CNAME", content: "t", proxied: true },
        { id: "p2", name: "www.rb.run",         type: "CNAME", content: "t", proxied: true }
      ] })
    stub_request(:get, records_url).with(query: hash_including("page" => "2", "per_page" => "100"))
      .to_return_json(body: { success: true, result_info: { total_pages: 2 }, result: [
        { id: "p3", name: "bbb-preview.rb.run", type: "CNAME", content: "t", proxied: false }
      ] })

    records = build.list(name_suffix: "-preview.rb.run")
    assert_equal %w[aaa-preview.rb.run bbb-preview.rb.run], records.map(&:name).sort
  end

  def test_list_passes_the_type_filter_through
    req = stub_request(:get, records_url).with(query: hash_including("type" => "CNAME", "page" => "1"))
      .to_return_json(body: { success: true, result_info: { total_pages: 1 }, result: [] })
    assert_empty build.list(type: "CNAME")
    assert_requested req
  end

  def test_api_error_raises_loud
    stub_request(:get, records_url).with(query: hash_including("name" => "a.rb.run"))
      .to_return_json(body: { success: false, errors: [ { message: "Invalid zone" } ], result: nil }, status: 403)
    error = assert_raises(Rbrun::Dns::Error) { build.find(name: "a.rb.run") }
    assert_match(/Invalid zone/, error.message)
  end
end
