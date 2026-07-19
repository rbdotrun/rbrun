Rbrun.configure do |c|
  c.database_connection = :primary      # dummy uses one sqlite DB; no separate connection
  c.tenancy_key         = "tenant"
  c.sandbox_provider    = { default: :local, local: {} }
  c.runtime_provider    = { default: :claude_sdk, claude_sdk: { anthropic_api_key: "sk-test-dummy" } }
  c.user email: "dev@rbrun.test", password: "password", tenant: "rbrun"
end
