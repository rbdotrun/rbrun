module Rbrun
  module Tools
    # Level 3 of the exposure ladder: make ONE previewed service reachable by ANYONE WITH THE LINK, with
    # no account. GATED — needs_approval! — because opening something to the public is a human decision,
    # never the agent's. Strictly requires level 2: a service that is not previewed can never be public.
    # The sandbox itself is never opened; rbrun's own edge serves exactly this one service.
    class SharePublic < Rbrun::ApplicationTool
      needs_approval!

      description <<~TXT
        Make ONE running, previewed service publicly reachable — anyone with the link can open it WITHOUT
        an account. This is a bigger step than preview_service (which still requires the viewer to be
        authenticated), so it needs the user's approval. The service must already be previewed. NEVER
        share a database, a queue, or a worker — only something the user explicitly wants public.
      TXT

      parameter :name, type: "string", description: "the service name to share publicly", required: true

      def execute(name:)
        result = Rbrun::ServiceLauncher.new(worktree: session.worktree).share_public(name)
        case result
        when :unknown       then error("no such service: #{name}")
        when :not_running   then error("service #{name} is not running — start it first")
        when :not_previewed then error("service #{name} is not previewed — call preview_service first (public requires preview)")
        else { "data" => { "name" => name, "public" => true, "url" => result.preview_url } }
        end
      end
    end
  end
end
