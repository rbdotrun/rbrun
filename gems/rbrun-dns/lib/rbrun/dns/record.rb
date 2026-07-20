# frozen_string_literal: true

module Rbrun
  module Dns
    # One DNS record, provider-agnostic. `id` is the provider's handle (nil for a not-yet-created record);
    # `proxied` is Cloudflare's orange-cloud flag (ignored by providers without a proxy).
    Record = Data.define(:id, :name, :type, :content, :proxied)
  end
end
