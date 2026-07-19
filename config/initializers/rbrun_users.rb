# Idempotently upsert config-declared users into rbrun's own users table. The config is the
# declarative source for the auth-critical fields; the DB row is canonical and extensible.
Rails.application.config.to_prepare do
  next unless Rbrun::User.table_exists?

  Rbrun.config.users.each do |u|
    user = Rbrun::User.find_or_initialize_by(email: u[:email])
    user.password = u[:password]
    user.public_send("#{Rbrun.config.tenancy_key}=", u[:tenant])
    user.save!
  end
end
