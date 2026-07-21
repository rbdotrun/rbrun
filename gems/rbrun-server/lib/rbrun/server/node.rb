# frozen_string_literal: true

module Rbrun
  module Server
    # A provisioned server, provider-neutral. Plain value object, no framework.
    Node = Data.define(:id, :name, :ip, :status, :region)
  end
end
