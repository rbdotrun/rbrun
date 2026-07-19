require "test_helper"

# The tenant-resolvable config seam: Rbrun.config(tenant) + Rbrun.config_resolver, and the tenant
# threading through Rbrun.sandbox/runtime. Additive — with no resolver set, everything is the static
# global (self-host unchanged). The engine knows nothing of any host; it only offers the hook.
class TenantConfigTest < ActiveSupport::TestCase
  setup { Rbrun.reset_config! }
  # reset_config! clears the config resolver too, so it can never escape this file (the outer
  # test_helper teardown then restores the real dummy config). The github_repos seams are separate,
  # so clear them here as well. Public API only — no internal poking.
  teardown do
    Rbrun.reset_config!
    Rbrun.github_repos = nil
    Rbrun.github_repos_resolver = nil
  end

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

  # ── R1: the repo directory (github_repos) is tenant-aware ──────────────────
  test "github_repos default uses the tenant's PAT via config(tenant)" do
    Rbrun.config_resolver = ->(t) { Rbrun::Config.new.tap { |c| c.github_pat = "ghp_#{t}" } }
    lister = Rbrun.github_repos("acme")
    assert_instance_of Rbrun::GithubRepos, lister
    # Blank global PAT would raise; a per-tenant PAT means it builds fine.
    assert_nothing_raised { Rbrun.github_repos("acme") }
  end

  test "github_repos_resolver (per-tenant lister) wins over the default" do
    Rbrun.github_repos_resolver = ->(tenant) { "LISTER:#{tenant}" }
    assert_equal "LISTER:acme", Rbrun.github_repos("acme")
  end

  test "a static github_repos override wins over the default but not the resolver" do
    Rbrun.github_repos = :static
    assert_equal :static, Rbrun.github_repos("acme")

    Rbrun.github_repos_resolver = ->(t) { "LISTER:#{t}" }
    assert_equal "LISTER:acme", Rbrun.github_repos("acme")   # resolver takes precedence
  end
end
