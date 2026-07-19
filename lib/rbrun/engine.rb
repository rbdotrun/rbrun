module Rbrun
  class Engine < ::Rails::Engine
    isolate_namespace Rbrun

    # Ship the pre-built bundle: bun compiles Tailwind v4 + turbo/stimulus into app/assets/builds/rbrun.
    # The host's asset pipeline (Propshaft) serves it; the host never runs bun.
    initializer "rbrun.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/assets/builds").to_s
        app.config.assets.precompile += %w[ rbrun/rbrun.css rbrun/rbrun.js ]
      end
    end
  end
end
