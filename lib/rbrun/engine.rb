require "turbo-rails"
require "stimulus-rails"
require "lucide-rails"

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

    # Auth is mandatory — fail fast at boot if nothing provides it. Then seed skills from config
    # (warn-only; never clobbers the DB).
    config.after_initialize do
      Rbrun.config.validate!
      Rbrun.register_tool(Rbrun::Tools::AskUser) # built-in custom gate (autoload ready here, not in initializers)
      [ Rbrun::Tools::WorkflowCreate, Rbrun::Tools::ValidateStep, Rbrun::Tools::CancelWorkflow,
        Rbrun::Tools::WorkflowSearch, Rbrun::Tools::UseWorkflow ].each { |t| Rbrun.register_tool(t) }
      [ Rbrun::Tools::RepoServicesStart, Rbrun::Tools::RepoServicesRestart, Rbrun::Tools::RepoServicesStop,
        Rbrun::Tools::RepoServicesStatus, Rbrun::Tools::RepoServicesLogs ].each { |t| Rbrun.register_tool(t) }
      Rbrun::ApplicationTool.validate_tool_approvals! # a half-built custom_approval! fails boot
      Rbrun::SkillSeeder.seed_at_boot!
      Rbrun::McpSeeder.seed_at_boot!
    end
  end
end
