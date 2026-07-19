require "test_helper"

# The tenant-resolvable config seam: Rbrun.config(tenant) + Rbrun.config_resolver, and the tenant
# threading through Rbrun.sandbox/runtime. Additive — with no resolver set, everything is the static
# global (self-host unchanged). The engine knows nothing of any host; it only offers the hook.
class TenantConfigTest < ActiveSupport::TestCase
  setup    { Rbrun.reset_config! }
  # reset_config! clears the resolver too, so it can never escape this file (the outer test_helper
  # teardown then restores the real dummy config). Public API only — no internal poking.
  teardown { Rbrun.reset_config! }

  test "config(tenant) falls back to the static global when no resolver is set" do
    assert_same Rbrun.config, Rbrun.config("acme")
  end

  test "config(tenant) routes through the resolver; no-arg stays the global" do
    per_tenant = Rbrun::Config.new.tap { |c| c.github_pat = "ghp_acme" }
    Rbrun.config_resolver = ->(tenant) { tenant == "acme" ? per_tenant : Rbrun.config }

    assert_equal "ghp_acme", Rbrun.config("acme").github_pat
    assert_same Rbrun.config, Rbrun.config          # no tenant → global, resolver untouched
    assert_nil Rbrun.config.github_pat
  end

  test "Rbrun.sandbox(tenant:) consults config(tenant)" do
    Rbrun.config_resolver = ->(tenant) { raise "resolved:#{tenant}" }
    err = assert_raises(RuntimeError) { Rbrun.sandbox(tenant: "acme") }
    assert_equal "resolved:acme", err.message
  end

  test "Rbrun.runtime(tenant:) consults config(tenant)" do
    Rbrun.config_resolver = ->(tenant) { raise "resolved:#{tenant}" }
    err = assert_raises(RuntimeError) { Rbrun.runtime(tenant: "acme", sandbox: Object.new) }
    assert_equal "resolved:acme", err.message
  end

  test "sandbox/runtime with no tenant never touch the resolver" do
    Rbrun.config_resolver = ->(_tenant) { raise "resolver must not be called without a tenant" }
    # config(nil) returns the global; build fails later on the empty provider, not via the resolver.
    assert_nothing_raised { Rbrun.config }
  end

  test "reset_config! clears the resolver too" do
    Rbrun.config_resolver = ->(_t) { raise "stale" }
    Rbrun.reset_config!
    assert_same Rbrun.config, Rbrun.config("acme")
  end
end
