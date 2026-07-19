require "test_helper"

class ConfigTest < ActiveSupport::TestCase
  setup { Rbrun.reset_config! }

  test "sane defaults" do
    c = Rbrun.config
    assert_equal :rbrun, c.database_connection
    assert_equal 900, c.subprocess_timeout
    assert_equal "tenant", c.tenancy_key
    assert_nil c.github_pat
    assert_equal [], c.users
    assert_equal({}, c.sandbox_provider)
    assert_equal({}, c.runtime_provider)
  end

  test "configure yields the config and returns it" do
    returned = Rbrun.configure do |c|
      c.subprocess_timeout = 1200
      c.github_pat = "ghp_x"
    end
    assert_equal 1200, Rbrun.config.subprocess_timeout
    assert_equal "ghp_x", Rbrun.config.github_pat
    assert_same Rbrun.config, returned
  end

  test "c.user appends identities with default tenant rbrun" do
    Rbrun.configure do |c|
      c.user email: "a@x.com", password: "p1"
      c.user email: "b@x.com", password: "p2", tenant: "acme"
    end
    assert_equal(
      [
        { email: "a@x.com", password: "p1", tenant: "rbrun" },
        { email: "b@x.com", password: "p2", tenant: "acme" }
      ],
      Rbrun.config.users
    )
  end

  test "c.skill collects inline skills (shorthand + kwargs) and c.skills_path stores the dir" do
    Rbrun.configure do |c|
      c.skills_path = "/app/skills"
      c.skill "pdf-report", "# PDF\n"
      c.skill slug: "invoice", name: "Invoice", files: { "SKILL.md" => "# Inv\n", "t.tex" => "x" }
      c.skill "multi", files: { "SKILL.md" => "m", "a.txt" => "b" }
    end
    assert_equal "/app/skills", Rbrun.config.skills_path
    assert_equal(
      [
        { slug: "pdf-report", name: "pdf-report", files: { "SKILL.md" => "# PDF\n" } },
        { slug: "invoice", name: "Invoice", files: { "SKILL.md" => "# Inv\n", "t.tex" => "x" } },
        { slug: "multi", name: "multi", files: { "SKILL.md" => "m", "a.txt" => "b" } }
      ],
      Rbrun.config.skills
    )
  end

  test "c.skill without a slug raises" do
    assert_raises(ArgumentError) { Rbrun.config.skill(name: "no slug") }
  end

  test "family provider hashes store and read; unset returns {}" do
    Rbrun.configure do |c|
      c.sandbox_provider = { default: :daytona, daytona: { api_key: "k" }, local: {} }
    end
    assert_equal :daytona, Rbrun.config.sandbox_provider[:default]
    assert_equal({ api_key: "k" }, Rbrun.config.sandbox_provider[:daytona])
    assert_equal({}, Rbrun.config.runtime_provider)
  end

  test "reset_config! wipes prior state" do
    Rbrun.configure { |c| c.github_pat = "ghp_x" }
    Rbrun.reset_config!
    assert_nil Rbrun.config.github_pat
  end
end
