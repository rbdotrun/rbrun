module Rbrun
  module Tools
    # Expose ONE running service for preview. A separate, explicit decision — starting a service never
    # exposes it. Declarative: it records the intent on the repo's service definition, so a later restart
    # keeps the service previewed. Ungated (it resolves a provider URL that still requires the viewer's
    # own authentication; it never makes the box public).
    class PreviewService < Rbrun::ApplicationTool
      description <<~TXT
        Make one running service previewable, so the user can open it in a browser. Use ONLY when the user
        wants to look at a service that serves HTTP — starting a service does NOT expose it. The service
        must declare a port. The decision sticks: restarting keeps it previewed until stop_preview.
      TXT

      parameter :name, type: "string", description: "the service name to preview", required: true

      def execute(name:)
        result = Rbrun::ServiceLauncher.new(worktree: session.worktree).preview(name)
        case result
        when :unknown     then error("no such service: #{name}")
        when :no_port     then error("service #{name} declares no port — nothing to preview")
        when :unsupported then error("this sandbox provider cannot publish a port")
        when :not_running then error("service #{name} is not running — start it first")
        else { "data" => { "name" => result.name, "port" => result.port, "url" => result.url, "previewed" => true } }
        end
      end
    end
  end
end
