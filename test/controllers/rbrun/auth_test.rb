require "test_helper"

module Rbrun
  class AuthTest < ActionDispatch::IntegrationTest
    test "config validate! raises when no auth is configured" do
      saved = Rbrun.instance_variable_get(:@config)
      Rbrun.reset_config!
      error = assert_raises(Rbrun::ConfigError) { Rbrun.config.validate! }
      assert_match(/requires auth/i, error.message)
    ensure
      Rbrun.instance_variable_set(:@config, saved)
    end

    test "an unauthenticated request redirects to login" do
      get "/rbrun/c"
      assert_redirected_to "/rbrun/login"
    end

    test "login with the seeded dev user establishes a session" do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      assert_redirected_to "/rbrun/c"
    end

    test "login with bad credentials re-renders unprocessable" do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "nope" }
      assert_response :unprocessable_entity
    end
  end
end
