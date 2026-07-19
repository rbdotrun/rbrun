require "test_helper"

class TenantedTest < ActiveSupport::TestCase
  test "for_tenant scopes on the configured tenancy_key column" do
    # Rbrun::Session includes Tenanted; the dummy configures tenancy_key = "tenant".
    a = rbrun_session(tenant: "acme")
    b = rbrun_session(tenant: "globex")
    assert_includes Rbrun::Session.for_tenant("acme"), a
    refute_includes Rbrun::Session.for_tenant("acme"), b
    assert_equal "acme", a.tenant
  end
end
