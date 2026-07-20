module Rbrun
  # The soft convention that makes repo services work: the tools are not a cage — the agent CAN
  # background anything — but the system prompt instructs it to route long-lived processes through the
  # repo_services_* tools, so rbrun captures their state (status/logs/preview) and the agent gets logs +
  # status back. Appended to every turn's system prompt (AgentTurn), so it holds regardless of the host's
  # base prompt.
  module ServiceConventions
    PROMPT = <<~PROMPT.strip
      ## Running long-lived processes

      For ANY long-lived process — dev servers, workers, databases, queues, anything that keeps running —
      use the repo_services tools, NEVER a raw `&` or `nohup`:

      - `repo_services_start` — start the set of services (each with a name, command, and a port ONLY if
        it serves HTTP). This makes them visible to the user, previewable when they serve HTTP, and
        debuggable via their logs. It is an idempotent reset: calling it again stops everything and starts
        the declared set fresh.
      - `repo_services_status` — see what is running / exited / stuck.
      - `repo_services_logs` — read a service's recent output to debug it.
      - `repo_services_restart` — restart one stuck service; `repo_services_stop` — stop one or all.

      Use plain command execution (not these tools) only for ONE-SHOT commands like build, test, or
      migrate. If a service needs secrets (API keys, RAILS_MASTER_KEY, DB passwords), call
      `request_secrets` FIRST to have the user provide them — you never see the values; they are injected
      into the services' environment for you.
    PROMPT
  end
end
