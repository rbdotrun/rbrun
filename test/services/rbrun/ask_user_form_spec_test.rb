require "test_helper"

module Rbrun
  class AskUserFormSpecTest < ActiveSupport::TestCase
    SPEC = { "title" => "Pick", "steps" => [ { "questions" => [
      { "key" => "region", "label" => "Which region?", "input" => "radio", "required" => true,
        "options" => [ { "value" => "idf", "label" => "Île-de-France" }, { "value" => "paca", "label" => "PACA" } ] },
      { "key" => "sectors", "label" => "Sectors?", "input" => "checkbox",
        "options" => [ { "value" => "tech", "label" => "Tech" }, { "value" => "food", "label" => "Food" } ] } ] } ] }.freeze

    def spec = Rbrun::AskUserFormSpec.new(SPEC)

    test "reads keys, option values, and value→label" do
      assert_equal %w[region sectors], spec.keys
      assert_equal %w[idf paca], spec.option_values("region")
      assert spec.multiple?("sectors")
      assert_equal "Île-de-France", spec.label_for("region", "idf")
    end

    test "errors: clean when valid" do
      assert_empty spec.errors("region" => [ "idf" ], "sectors" => [ "tech" ])
    end

    test "errors: a value outside the declared options" do
      assert_includes spec.errors("region" => [ "mars" ]).join, "invalid choice"
    end

    test "errors: a skipped required question" do
      assert_includes spec.errors("sectors" => [ "tech" ]).join, "is required"
    end

    test "errors: an unknown field" do
      assert_includes spec.errors("region" => [ "idf" ], "evil" => [ "x" ]).join, "unknown fields"
    end

    test "recap resolves labels (not machine values)" do
      recap = spec.recap("region" => [ "idf" ], "sectors" => [ "tech", "food" ])
      assert_includes recap, "Which region? → Île-de-France"
      assert_includes recap, "Sectors? → Tech, Food"
    end
  end
end
