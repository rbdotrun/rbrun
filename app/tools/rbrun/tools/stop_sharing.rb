module Rbrun
  module Tools
    # Revoke a service's public link. Ungated — withdrawing access is always safe. The service keeps
    # running and stays previewed; only the public route dies (and the token with it, permanently: a
    # later re-share mints a new one).
    class StopSharing < Rbrun::ApplicationTool
      description <<~TXT
        Revoke a service's PUBLIC link, so it is no longer reachable without an account. The service keeps
        running and remains previewed — only the public access is withdrawn.
      TXT

      parameter :name, type: "string", description: "the service name to stop sharing publicly", required: true

      def execute(name:)
        Rbrun::ServiceLauncher.new(worktree: session.worktree).stop_sharing(name)
        { "data" => { "name" => name, "public" => false } }
      end
    end
  end
end
