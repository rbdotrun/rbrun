require "test_helper"
require "rails/generators/test_case"
require "generators/rbrun/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Rbrun::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  test "creates the rbrun initializer" do
    run_generator
    assert_file "config/initializers/rbrun.rb", /Rbrun\.configure/, /sandbox_provider/, /tenancy_key/
  end
end
