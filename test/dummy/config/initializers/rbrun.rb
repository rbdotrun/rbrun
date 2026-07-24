Rbrun.configure do |c|
  c.database_connection = :primary      # dummy uses one sqlite DB; no separate connection


  # Sandbox: Daytona wherever creds are supplied (the deploy), else the local dir backend for tests and
  # laptop dev. Previews REQUIRE a sandbox that resolves preview URLs — only Daytona does.
  if ENV["DAYTONA_API_KEY"].present?
    c.sandbox_provider = {
      default: :daytona,
      daytona: {
        api_key: ENV["DAYTONA_API_KEY"],
        api_url: ENV.fetch("DAYTONA_API_URL", "https://app.daytona.io/api")
      }
    }
  else
    c.sandbox_provider = {
      default: :local,
      local: {}
    }
  end

  # Runtime: the Claude Agent SDK — configured ONLY when its credential is really present, exactly like
  # the DNS/server capabilities below. The config is valid, or it raises, or the capability is absent;
  # there is no third state. A placeholder key ("sk-test-dummy") was the worst of all worlds: it made an
  # INVALID config look valid, so claude_sdk's own fail-fast on a missing key could never fire, and an
  # unconfigured host silently got a runtime that would only fail on the first real API call.
  # model + max_turns are declared explicitly — the adapter no longer guesses them ("sonnet" is a moving
  # alias; max_turns is a real cost/latency budget).
  if ENV["ANTHROPIC_OAUTH_TOKEN"].present?
    c.runtime_provider = {
      default: :claude_sdk,
      claude_sdk: {
        anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"],
        model: ENV.fetch("RBRUN_MODEL", "sonnet"),
        max_turns: Integer(ENV.fetch("RBRUN_MAX_TURNS", 60))
      }
    }
  end

  # GitHub: the agent clones + pushes worktree branches and the repo switcher lists repos via this PAT.
  # Generated on the host with `gh auth token`.
  c.github_pat = ENV["GITHUB_PAT"]

  # DNS capability: when Cloudflare creds are present, the engine points deploy hosts (rbrun-w<id>.<domain>)
  # at the provisioned box's IP.
  if ENV["CLOUDFLARE_API_KEY"].present? && ENV["CLOUDFLARE_ZONE_ID"].present?
    c.dns_provider   = {
      default: :cloudflare,
      cloudflare: {
        api_token: ENV["CLOUDFLARE_API_KEY"],
        zone_id: ENV["CLOUDFLARE_ZONE_ID"]
      }
    }
    # No fallback domain — a distributed engine has no universal one. Absent ⇒ preview/deploy hosting is
    # blocked (provision_server fails loud), never silently pointed at someone else's domain.
    c.preview_domain = ENV["RBRUN_PREVIEW_DOMAIN"].presence
  end

  # Server (deploy) capability: Hetzner provisioning + Kamal deploy, when creds are present. The SSH
  # keypair is generated + stored per deployment (engine-owned), never config.
  if ENV["HETZNER_API_TOKEN"].present?
    c.server_provider = {
      default: :kamal_hetzner,
      kamal_hetzner: {
        hcloud_token: ENV["HETZNER_API_TOKEN"],
        registry: {
          server:   ENV["KAMAL_REGISTRY_SERVER"],
          username: ENV["KAMAL_REGISTRY_USERNAME"],
          password: ENV["KAMAL_REGISTRY_PASSWORD"]
        }
      }
    }
  end

  c.user email: "dev@rbrun.test", password: "password", tenant: "rbrun"
end
