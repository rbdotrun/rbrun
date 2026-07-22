# Development-only: load the repo-root .env into ENV (it lives at the repo root, not the dummy's
# Rails.root, which is test/dummy). Never in test — .env holds real provider creds (Daytona, Anthropic,
# Hetzner, …) that would flip the dummy initializer onto live providers and break the offline suite.
# Runs before rbrun.rb (alphabetical), so Rbrun.configure sees the loaded ENV.
if Rails.env.development?
  require "dotenv"
  Dotenv.load(Rails.root.parent.parent.join(".env").to_s)
end
