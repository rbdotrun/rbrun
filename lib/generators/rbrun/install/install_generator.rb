require "rails/generators/base"

module Rbrun
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/rbrun.rb and prints the remaining install steps."

      def create_initializer
        template "rbrun.rb", "config/initializers/rbrun.rb"
      end

      def show_next_steps
        say "\nrbrun installed. Next:", :green
        say "  1. Fill in config/initializers/rbrun.rb (API keys, providers)."
        say "  2. If database_connection is :rbrun, add an 'rbrun' entry under each env in config/database.yml."
        say "  3. bin/rails rbrun:install:migrations && bin/rails db:migrate"
      end
    end
  end
end
