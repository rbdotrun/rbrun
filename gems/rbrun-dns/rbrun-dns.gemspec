require_relative "lib/rbrun/dns/version"

Gem::Specification.new do |spec|
  spec.name        = "rbrun-dns"
  spec.version     = Rbrun::Dns::VERSION
  spec.authors     = [ "rbdotrun" ]
  spec.summary     = "DNS providers for rbrun (cloudflare) behind one upsert/find/remove contract."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "README.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "async", ">= 2.0"
  spec.add_dependency "async-http", ">= 0.60"
  spec.add_dependency "async-http-faraday", ">= 0.12"
  spec.add_dependency "faraday", "~> 2.0"

  spec.add_development_dependency "webmock", "~> 3.0"
end
