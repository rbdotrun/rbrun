module Rbrun
  module Tools
    # Withdraw a service's preview. Declarative counterpart of preview_service: clears the intent on the
    # repo's service definition and forgets the resolved URL. The service KEEPS RUNNING — this only stops
    # it being previewable.
    class StopPreview < Rbrun::ApplicationTool
      description <<~TXT
        Stop previewing a service. The service keeps running — this only withdraws its preview link, so it
        is no longer openable from the browser. The decision sticks across restarts.
      TXT

      parameter :name, type: "string", description: "the service name to stop previewing", required: true

      def execute(name:)
        result = Rbrun::ServiceLauncher.new(worktree: session.worktree).stop_preview(name)
        case result
        when :unknown     then error("no such service: #{name}")
        when :not_running then { "data" => { "name" => name, "previewed" => false } }
        else { "data" => { "name" => result.name, "url" => nil, "previewed" => false } }
        end
      end
    end
  end
end
