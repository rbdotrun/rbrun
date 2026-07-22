Rbrun.configure do |c|
  c.database_connection = :primary      # dummy uses one sqlite DB; no separate connection
  c.tenancy_key         = "tenant"

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

  # Runtime: the Claude Agent SDK. Real OAuth token in the deploy; a dummy key keeps tests fully offline.
  c.runtime_provider = {
    default: :claude_sdk,
    claude_sdk: {
      anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"].presence || "sk-test-dummy"
    }
  }

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
    c.preview_domain = ENV.fetch("RBRUN_PREVIEW_DOMAIN", "rb.run")
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
