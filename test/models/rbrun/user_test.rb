require "test_helper"

module Rbrun
  class UserTest < ActiveSupport::TestCase
    test "config-seeded dev user exists with tenant and a working password" do
      user = User.find_by(email: "dev@rbrun.test")
      assert user, "dummy initializer seeds dev@rbrun.test"
      assert_equal "rbrun", user.tenant
      assert user.authenticate("password")
      refute user.authenticate("wrong")
    end

    test "email is unique" do
      User.create!(email: "u@x.com", password: "pw", tenant: "acme")
      assert_raises(ActiveRecord::RecordInvalid) { User.create!(email: "u@x.com", password: "pw", tenant: "acme") }
    end

    test "current_tenant falls back to the default slug when no resolver is set" do
      Rbrun.current_tenant_resolver = nil
      assert_equal "rbrun", Rbrun.current_tenant
    end
  end
end
