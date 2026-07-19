# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

# Rbrun.config is global singleton state, set once by test/dummy's initializer. A test that mutates
# it (e.g. reset_config! to exercise config parsing) would otherwise leak an empty/altered config
# into whatever test runs next under a different seed. Snapshot the config object before each test
# and restore it after, so config mutation can never cross test boundaries.
class ActiveSupport::TestCase
  setup    { @__rbrun_config = Rbrun.instance_variable_get(:@config) }
  teardown { Rbrun.instance_variable_set(:@config, @__rbrun_config) }
end
