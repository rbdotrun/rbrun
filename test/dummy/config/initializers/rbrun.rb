Rbrun.configure do |c|
  c.database_connection = :primary      # dummy uses one sqlite DB; no separate connection
  c.tenancy_key         = "tenant"

  # Sandbox: Daytona wherever creds are supplied (the deploy), else the local dir backend for tests and
  # laptop dev. Previews REQUIRE a sandbox that resolves preview URLs — only Daytona does.
  if ENV["DAYTONA_API_KEY"].present?
    c.sandbox_provider = { default: :daytona, daytona: {
      api_key: ENV["DAYTONA_API_KEY"],
      api_url: ENV.fetch("DAYTONA_API_URL", "https://app.daytona.io/api")
    } }
  else
    c.sandbox_provider = { default: :local, local: {} }
  end

  # Runtime: the Claude Agent SDK. Real OAuth token in the deploy; a dummy key keeps tests fully offline.
  c.runtime_provider = { default: :claude_sdk, claude_sdk: {
    anthropic_api_key: ENV["ANTHROPIC_OAUTH_TOKEN"].presence || "sk-test-dummy"
  } }

  # DNS capability + preview edge: when Cloudflare creds are present, the engine creates ONE record per
  # shared preview — <token>-preview.<preview_domain> -> preview_target. preview_target is THIS app's own
  # public origin (the deployed box), never a tunnel; each preview host CNAMEs here and the request lands
  # back on the PreviewProxy, which relays into the private sandbox.
  if ENV["CLOUDFLARE_API_KEY"].present? && ENV["CLOUDFLARE_ZONE_ID"].present?
    c.dns_provider   = { default: :cloudflare, cloudflare: {
      api_token: ENV["CLOUDFLARE_API_KEY"], zone_id: ENV["CLOUDFLARE_ZONE_ID"]
    } }
    c.preview_domain = ENV.fetch("RBRUN_PREVIEW_DOMAIN", "rb.run")
    c.preview_target = ENV.fetch("RBRUN_PREVIEW_TARGET", "dev.rb.run")
  end

  c.user email: "dev@rbrun.test", password: "password", tenant: "rbrun"
end
