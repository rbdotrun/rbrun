# rbrun configuration. See docs for every knob.
Rbrun.configure do |c|
  c.database_connection = :rbrun            # :rbrun (own DB) | :primary (host DB)
  c.subprocess_timeout  = 900
  c.github_pat          = ENV["GITHUB_PAT"] # agent's GitHub access (staged into the sandbox per-turn)
  c.tenancy_key         = "tenant"          # name of the required slug column scoping every record

  # Built-in auth (optional; omit ⇒ your app supplies Rbrun.current_tenant). Repeatable.
  # c.user email: "you@example.com", password: ENV["RBRUN_PW"], tenant: "default"

  c.runtime_provider = {
    default:    :claude_sdk,
    claude_sdk: { anthropic_api_key: ENV["ANTHROPIC_API_KEY"], model: "sonnet", max_turns: 60 }
  }

  c.sandbox_provider = {
    default: :daytona,
    daytona: { api_key: ENV["DAYTONA_API_KEY"], api_url: ENV["DAYTONA_API_URL"] },
    local:   {}
  }
end
