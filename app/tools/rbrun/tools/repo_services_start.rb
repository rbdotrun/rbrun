module Rbrun
  module Tools
    # Start this repo's long-lived services — the sanctioned, gated way to run anything that keeps
    # running, so rbrun captures its state (status/logs/preview). needs_approval!: one gate for the whole
    # set. On approval the frozen execute runs the idempotent ServiceLauncher#start.
    class RepoServicesStart < Rbrun::ApplicationTool
      needs_approval!

      description <<~TXT
        Start this repo's long-lived services (web servers, workers, databases, queues) — the sanctioned
        way to run anything that KEEPS RUNNING, so it is visible to the user, previewable if it serves
        HTTP, and debuggable via its logs. Idempotent reset: stops everything running in this worktree,
        then starts the declared set fresh; saves the set for reuse. Give each service a short `name`, its
        `command`, and a `port` ONLY when it serves HTTP. Use plain command execution (not this) for
        one-shot commands like build/test/migrate.
        Starting a service does NOT expose it: `port` is only what the process binds to INSIDE the box.
        Making a service viewable in a browser is a separate, explicit call to `preview_service`.
        Example: { "services": [ { "name": "web", "command": "bin/rails s -p 3000", "port": 3000 },
                                  { "name": "css", "command": "bin/rails tailwindcss:watch" } ] }
      TXT

      parameter :services, type: "array",
                items: -> {
                  { "type" => "object",
                    "properties" => {
                      "name"    => { "type" => "string",  "description" => "short service name (e.g. web, worker, db)" },
                      "command" => { "type" => "string",  "description" => "the command to run" },
                      "port"    => { "type" => "integer", "description" => "the HTTP port — ONLY if it serves HTTP" }
                    },
                    "required" => %w[name command] }
                },
                description: "the services to run: [{ name, command, port? }]", required: true

      def execute(services:)
        launcher = Rbrun::ServiceLauncher.new(worktree: session.worktree)
        launcher.start(services)
        { "data" => { "services" => launcher.status.map { |r|
          { "name" => r.name, "port" => r.port, "status" => r.status, "url" => r.url }
        } } }
      end
    end
  end
end
