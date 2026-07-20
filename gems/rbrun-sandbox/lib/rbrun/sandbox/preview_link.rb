# frozen_string_literal: true

module Rbrun
  module Sandbox
    # A resolved preview: the public URL for a port inside a box, plus the auth token (nil for a public
    # port or a localhost box). An OPTIONAL capability — only adapters that can publish a port define
    # #preview_url and return one; the engine probes respond_to?(:preview_url).
    PreviewLink = Data.define(:url, :token)
  end
end
