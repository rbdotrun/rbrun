namespace :rbrun do
  namespace :skills do
    desc "Seed skills from config (skills_path + inline) into the DB — compare, never clobber"
    task seed: :environment do
      tenant = ENV["RBRUN_TENANT"].presence || Rbrun::Config::DEFAULT_TENANT
      Rbrun::SkillSeeder.from_config(Rbrun.config, tenant: tenant).call.each do |r|
        line = "#{r.status.to_s.ljust(10)} #{r.slug}"
        line += " — #{r.message}" if r.message
        puts line
      end
    end
  end
end
