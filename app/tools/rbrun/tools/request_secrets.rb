module Rbrun
  module Tools
    # Ask the user to provide secrets/env the app needs to run (API keys, RAILS_MASTER_KEY, DB
    # passwords). A custom gate (sibling of ask_user): the run parks and a SECURE form renders. The agent
    # declares only the KEYS — it NEVER sees the values, which are stored encrypted and injected into the
    # services' environment (ServiceSupervisor#write_env!).
    #
    # No execute: a gate tool's operation is the user's submission; custom_approval! supplies the degrade.
    class RequestSecrets < Rbrun::ApplicationTool
      custom_approval! submit: :secrets_submission

      description <<~TXT
        Ask the user to provide secrets / environment values the app needs to run (API keys,
        RAILS_MASTER_KEY, database passwords). Declare ONLY the keys you need — you will NEVER receive the
        values; they are stored securely and injected into the services' environment for you. Use this
        before starting services that need secrets. `secrets` is a list:
          { "secrets": [ { "key": "RAILS_MASTER_KEY", "label": "Rails master key", "required": true,
                           "hint": "from config/master.key" } ] }
      TXT

      parameter :secrets, type: "array", items: -> { { "type" => "object" } },
                description: "the secrets to request: [{ key, label, required?, hint? }]", required: true
    end
  end
end
