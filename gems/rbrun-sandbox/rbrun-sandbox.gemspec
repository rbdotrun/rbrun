require_relative "lib/rbrun/sandbox/version"

Gem::Specification.new do |spec|
  spec.name        = "rbrun-sandbox"
  spec.version     = Rbrun::Sandbox::VERSION
  spec.authors     = [ "Ben" ]
  spec.summary     = "Sandbox backends for rbrun (local, daytona) behind one exec/file/session contract."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "async", ">= 2.0"
  spec.add_dependency "async-http", ">= 0.60"
  spec.add_dependency "async-http-faraday", ">= 0.12"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-multipart", "~> 1.0"
end
