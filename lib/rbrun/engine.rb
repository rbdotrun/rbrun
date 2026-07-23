require "turbo-rails"
require "stimulus-rails"
require "lucide-rails"
# Load ViewComponent's engine eagerly (it's otherwise pulled in lazily via view_component_contrib) so
# its config.view_component exists by the time our initializer below turns previews off.
require "view_component"

module Rbrun
  class Engine < ::Rails::Engine
    isolate_namespace Rbrun

    # Ship the pre-built bundle: bun compiles Tailwind v4 + turbo/stimulus into app/assets/builds/rbrun.
    # The host's asset pipeline (Propshaft) serves it; the host never runs bun.
    # Never let a submitted secret leak into logs — the request_secrets form posts secrets[...] values.
    initializer "rbrun.filter_parameters" do |app|
      app.config.filter_parameters += [ :secrets, :value, :token ]
    end

    initializer "rbrun.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/assets/builds").to_s
        app.config.assets.precompile += %w[ rbrun/rbrun.css rbrun/rbrun.js ]
      end
    end

    # rbrun pulls in ViewComponent (via view_component_contrib). Its dev preview UI registers a
    # `preview_view_components` route that RE-ADDS itself on every routes reload → "Invalid route name,
    # already in use" and a forced restart after each code change. rbrun's components are covered by the
    # primitives smoke test, not previews, so turn previews off. Set here (an engine initializer runs
    # after ViewComponent's railtie defines config.view_component, and before routes are drawn — the env
    # file and config/initializers are too early: config.view_component doesn't exist there yet).
    initializer "rbrun.disable_view_component_previews", after: "view_component.set_configs" do |app|
      # (No respond_to? guard — config.view_component is method_missing-backed, so respond_to? is false
      # even though it's set. set_configs ran just before, so the object is present.)
      app.config.view_component.show_previews = false
    end

    # Auth is mandatory — fail fast at boot if nothing provides it. Then seed skills from config
    # (warn-only; never clobbers the DB).
    config.after_initialize do
      Rbrun.config.validate!
      Rbrun.register_tool(Rbrun::Tools::AskUser) # built-in custom gate (autoload ready here, not in initializers)
      [ Rbrun::Tools::WorkflowCreate, Rbrun::Tools::ValidateStep, Rbrun::Tools::CancelWorkflow,
        Rbrun::Tools::WorkflowSearch, Rbrun::Tools::UseWorkflow ].each { |t| Rbrun.register_tool(t) }
      Rbrun.register_tool(Rbrun::Tools::SaveArtifact) # ungated: a produced deliverable is leaf output
      Rbrun.register_tool(Rbrun::Tools::SaveSkill)    # gated: a promoted skill steers every future turn
      [ Rbrun::Tools::DeployConfig, Rbrun::Tools::ListDeploySecrets, Rbrun::Tools::ProvisionServer,
        Rbrun::Tools::CreateDeployDns, Rbrun::Tools::Deploy, Rbrun::Tools::DeployStatus,
        Rbrun::Tools::DeployLogs, Rbrun::Tools::DeployExec,
        Rbrun::Tools::TeardownDeploy ].each { |t| Rbrun.register_tool(t) }
      Rbrun.register_tool(Rbrun::Tools::RequestSecrets) # custom gate (card + :secrets_submission route required)
      Rbrun::ApplicationTool.validate_tool_approvals! # a half-built custom_approval! fails boot
      Rbrun::SkillSeeder.seed_at_boot!
      Rbrun::McpSeeder.seed_at_boot!
    end
  end
end
