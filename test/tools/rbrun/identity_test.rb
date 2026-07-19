require "test_helper"

module Rbrun
  module Tools
    class IdentityTest < ActiveSupport::TestCase
      test "identity is registered and returns tenant + session id" do
        assert_includes Rbrun.tools, Rbrun::Tools::Identity
        session = rbrun_session(tenant: "acme")
        out = Identity.in_session(session).execute
        assert_equal "acme", out.dig("data", "tenant")
        assert_equal session.id, out.dig("data", "session_id")
      end

      test "default system_prompt names the identity tool" do
        assert_includes Rbrun.config.system_prompt, "identity"
      end
    end
  end
end
