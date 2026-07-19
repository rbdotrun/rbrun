require_relative "lib/rbrun/runtime/version"

Gem::Specification.new do |spec|
  spec.name        = "rbrun-runtime"
  spec.version     = Rbrun::Runtime::VERSION
  spec.authors     = [ "rbdotrun" ]
  spec.summary     = "AI runtime for rbrun: a sandboxed Claude Agent SDK runner behind one run(...) contract."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rbrun-sandbox"
end
