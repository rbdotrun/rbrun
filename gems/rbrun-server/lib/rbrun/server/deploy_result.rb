# frozen_string_literal: true

module Rbrun
  module Server
    # The outcome of a deploy: ok? + captured output. Plain value object.
    DeployResult = Data.define(:ok, :output)
  end
end
