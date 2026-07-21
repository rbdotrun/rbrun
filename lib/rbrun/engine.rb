require "turbo-rails"
require "stimulus-rails"
require "lucide-rails"

module Rbrun
  class Engine < ::Rails::Engine
    isolate_namespace Rbrun

    # Ship the pre-built bundle: bun compiles Tailwind v4 + turbo/stimulus into app/assets/builds/rbrun.
    # The host's asset pipeline (Propshaft) serves it; the host never runs bun.
    # Never let a submitted secret leak into logs — the request_secrets form posts secrets[...] values.
    initializer "rbrun.filter_parameters" do |app|
      app.config.filter_parameters += [ :secrets, :value, :token ]
    end

    # The preview edge. Inserted at the TOP of the stack so it intercepts EVERY path on a preview host —
    # including /assets, which ActionDispatch::Static would otherwise grab first. No-ops for non-preview
    # hosts and when the host app owns the edge (Rbrun.preview_edge). (Being above the session middleware,
    # the private-preview gate cannot read the rbrun session here — level-2 auth needs a cross-subdomain
    # handshake, a follow-up; public previews are fully served.)
    initializer "rbrun.preview_proxy" do |app|
      require "rbrun/preview_proxy"
      app.middleware.insert_before(0, Rbrun::PreviewProxy)
    end

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
        Rbrun::Tools::RepoServicesStatus, Rbrun::Tools::RepoServicesLogs,
        Rbrun::Tools::PreviewService, Rbrun::Tools::StopPreview,
        Rbrun::Tools::SharePublic, Rbrun::Tools::StopSharing ].each { |t| Rbrun.register_tool(t) }
      [ Rbrun::Tools::DeployRegistry, Rbrun::Tools::ProvisionServer, Rbrun::Tools::CreateDeployDns,
        Rbrun::Tools::Deploy, Rbrun::Tools::DeployStatus, Rbrun::Tools::DeployLogs, Rbrun::Tools::TeardownDeploy
      ].each { |t| Rbrun.register_tool(t) }
      Rbrun.register_tool(Rbrun::Tools::RequestSecrets) # custom gate (card + :secrets_submission route required)
      Rbrun::ApplicationTool.validate_tool_approvals! # a half-built custom_approval! fails boot
      Rbrun::SkillSeeder.seed_at_boot!
      Rbrun::McpSeeder.seed_at_boot!
      # No boot-time DNS: preview records are created per-share on expose, deleted on stop, and a Sentinel
      # reconciles leftovers.
    end
  end
end
