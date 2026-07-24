require "test_helper"

module Rbrun
  # ONE authority per deployment, decided by which seam is INSTALLED — never an `||` across both.
  #
  # Rbrun.current_user_from returns nil in two OPPOSITE situations: no host resolver is configured, and
  # the host resolver saying "this person is not signed in". OR-ing past it treated a rejection as an
  # absence and fell through to rbrun's own password form + session cookie.
  class HostAuthTest < ActionDispatch::IntegrationTest
    teardown { Rbrun.current_user_resolver = nil }

    test "with no host resolver, rbrun's built-in login is the authority" do
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      get "/rbrun/c"
      assert_response :success
    end

    test "a host-logged-out user CANNOT get in through rbrun's built-in login" do
      # Sign in through the built-in form first — this is the cookie the fallback used to honour.
      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      get "/rbrun/c"
      assert_response :success

      # Now the host owns auth and says: not signed in.
      Rbrun.current_user_resolver = ->(_session) { nil }

      get "/rbrun/c"
      assert_redirected_to "/rbrun/login", "the host's rejection must be final — no cookie fallback"
    end

    test "the host's verdict is used verbatim when it DOES return a user" do
      user = Rbrun::User.find_by(email: "dev@rbrun.test")
      Rbrun.current_user_resolver = ->(_session) { user }

      get "/rbrun/c" # no rbrun login performed at all
      assert_response :success
    end

    test "the built-in login is refused outright while the host owns auth (no second door)" do
      Rbrun.current_user_resolver = ->(_session) { nil }

      get "/rbrun/login"
      assert_response :not_found

      post "/rbrun/login", params: { email: "dev@rbrun.test", password: "password" }
      assert_response :not_found
    end
  end
end
