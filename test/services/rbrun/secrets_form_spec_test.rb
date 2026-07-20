require "test_helper"

module Rbrun
  class SecretsFormSpecTest < ActiveSupport::TestCase
    SPEC = { "secrets" => [
      { "key" => "RAILS_MASTER_KEY", "label" => "Rails master key", "required" => true, "hint" => "from config/master.key" },
      { "key" => "SENTRY_DSN", "label" => "Sentry DSN" }
    ] }.freeze

    def spec = Rbrun::SecretsFormSpec.new(SPEC)

    test "reads keys, labels, hints, required" do
      assert_equal %w[RAILS_MASTER_KEY SENTRY_DSN], spec.keys
      assert_equal "Rails master key", spec.label_for("RAILS_MASTER_KEY")
      assert_equal "from config/master.key", spec.hint_for("RAILS_MASTER_KEY")
      assert spec.required?("RAILS_MASTER_KEY")
      refute spec.required?("SENTRY_DSN")
    end

    test "errors: clean when required present, flags missing required + unknown fields" do
      assert_empty spec.errors("RAILS_MASTER_KEY" => "abc")
      assert_includes spec.errors("SENTRY_DSN" => "x").join, "is required"
      assert_includes spec.errors("RAILS_MASTER_KEY" => "abc", "EVIL" => "x").join, "unknown fields"
    end

    test "stored_recap lists KEY NAMES only — never a value" do
      recap = spec.stored_recap(%w[RAILS_MASTER_KEY])
      assert_includes recap, "RAILS_MASTER_KEY"
      refute_includes recap, "abc", "no value ever appears in the recap"
    end
  end
end
