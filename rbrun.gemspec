require_relative "lib/rbrun/version"

Gem::Specification.new do |spec|
  spec.name        = "rbrun"
  spec.version     = Rbrun::VERSION
  spec.authors     = [ "rbdotrun" ]
  spec.email       = [ "ben@rb.run" ]
  spec.homepage    = "https://github.com/rbdotrun/rbrun"
  spec.summary     = "A mountable Rails engine that runs an agentic Claude SDK runner (agentic runner + skill pattern + sandbox backend)."
  spec.description = "rbrun is a mountable Rails engine — conceptually a standalone agentic-runner application with its own database, assets, and optional auth — composed from provider sub-gems (rbrun-sandbox, rbrun-runtime)."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  # Publish gate: unset (blocks `gem push`) until we publish to RubyGems. To publish, set this to
  # "https://rubygems.org" (or delete the line). Until then, hosts consume from git — see README.
  spec.metadata["allowed_push_host"] = "https://rubygems.org/DISABLED-until-first-publish"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rbdotrun/rbrun"
  spec.metadata["changelog_uri"] = "https://github.com/rbdotrun/rbrun/blob/main/CHANGELOG.md"

  # The engine distributes the provider sub-gems by VENDORING their lib (packaged below + on the load
  # path via require_paths), NOT by depending on them. This keeps them pure, boundary-clean gems in
  # gems/ (their own gemspecs are the contract; the dev Gemfile still loads them as path gems, so the
  # boundary is enforced in tests) while a host installs ONE gem — `gem "rbrun", github: …` — with no
  # published sub-gems, no glob. If we publish the sub-gems one day, swap the require_paths entries
  # back to `add_dependency "rbrun-sandbox"/"rbrun-runtime"` and drop the vendored files.
  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "gems/rbrun-{sandbox,runtime}/lib/**/*",
        "MIT-LICENSE", "Rakefile", "README.md"]
  end
  spec.require_paths = [ "lib", "gems/rbrun-sandbox/lib", "gems/rbrun-runtime/lib" ]

  spec.add_dependency "rails", ">= 8.1.3"
  # Mirrors gems/rbrun-sandbox/rbrun-sandbox.gemspec — its externals must be declared here because the
  # engine vendors its lib instead of depending on the gem. (rbrun-runtime adds no external deps.)
  spec.add_dependency "async", ">= 2.0"
  spec.add_dependency "async-http", ">= 0.60"
  spec.add_dependency "async-http-faraday", ">= 0.12"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
  spec.add_dependency "ruby_llm"
  spec.add_dependency "bcrypt"
  spec.add_dependency "view_component", "~> 3.21"
  spec.add_dependency "view_component-contrib"
  spec.add_dependency "tailwind_merge"
  spec.add_dependency "dry-initializer"
  spec.add_dependency "lucide-rails"
  spec.add_dependency "redcarpet"
  spec.add_dependency "turbo-rails"
  spec.add_dependency "stimulus-rails"
end
