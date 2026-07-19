# frozen_string_literal: true

module Rbrun
  module Runtime
    class ClaudeSdk
      def initialize(sandbox:, config: {})
        @sandbox = sandbox
        @config = config
      end
    end
  end
end
