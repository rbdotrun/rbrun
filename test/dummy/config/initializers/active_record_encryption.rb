# Test/dummy keys for ActiveRecord encryption (Rbrun::RepoSecret#value). A real host sets its own via
# credentials; these deterministic keys exist so the engine's encrypted-secrets path is testable.
Rails.application.config.active_record.encryption.primary_key         = "test" * 8
Rails.application.config.active_record.encryption.deterministic_key   = "det!" * 8
Rails.application.config.active_record.encryption.key_derivation_salt = "salt" * 8
