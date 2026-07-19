# frozen_string_literal: true

module Rbrun
  module Sandbox
    # The normalized result of one command, from any adapter.
    ExecResult = Data.define(:exit_code, :stdout, :stderr) do
      def success? = exit_code.to_i.zero?
    end
  end
end
