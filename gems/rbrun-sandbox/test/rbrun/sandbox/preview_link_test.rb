# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class PreviewLinkTest < Minitest::Test
  # Local is a real executor — test it for real, no fake.
  def test_local_preview_url_is_localhost_no_token
    box = Rbrun::Sandbox::Local.new(config: { root: Dir.mktmpdir }, labels: { session: 1 })
    link = box.preview_url(3000)
    assert_instance_of Rbrun::Sandbox::PreviewLink, link
    assert_equal "http://localhost:3000", link.url
    assert_nil link.token
    assert_respond_to box, :preview_url
  end

  # The engine gates the feature on respond_to?(:preview_url) — assert the capability is PRESENT on the
  # Daytona adapter + its client. The Daytona wire ({url,token} shape, endpoint) is verified live in the
  # preview_daytona dogfood, not stubbed here.
  def test_daytona_declares_the_preview_capability
    assert_includes Rbrun::Sandbox::Daytona.instance_methods, :preview_url
    assert_includes Rbrun::Sandbox::Daytona::Client.instance_methods, :preview_link
  end
end
