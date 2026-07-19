source "https://rubygems.org"

# Specify your gem's dependencies in rbrun.gemspec.
gemspec

gem "puma"

gem "sqlite3"

gem "propshaft"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"

# Path-based sub-gems (rbrun-sandbox, rbrun-runtime, …) live under gems/.
# Each is auto-included as a path gem once its gemspec exists. No-op until then.
Dir.glob(File.expand_path("gems/*/*.gemspec", __dir__)).each do |gemspec_path|
  gem File.basename(gemspec_path, ".gemspec"), path: File.dirname(gemspec_path)
end
