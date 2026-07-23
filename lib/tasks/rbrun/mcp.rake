namespace :rbrun do
  namespace :mcp do
    desc "Seed MCP servers from config into the DB — compare, never clobber"
    task seed: :environment do
      tenant = ENV["RBRUN_TENANT"].presence || Rbrun::Config::DEFAULT_TENANT
      Rbrun::McpSeeder.from_config(Rbrun.config, tenant:).call.each do |r|
        puts "#{r.status.to_s.ljust(10)} #{r.name}"
      end
    end
  end
end
