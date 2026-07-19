module Rbrun
  # Optional built-in auth identity. Config-seeded (c.user), but the ROW is canonical and extensible —
  # add columns (roles, settings) without touching the config contract.
  class User < ApplicationRecord
    include Rbrun::Tenanted
    has_secure_password
    validates :email, presence: true, uniqueness: true
  end
end
