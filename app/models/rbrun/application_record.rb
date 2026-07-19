module Rbrun
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true

    # Own DB by default; :primary keeps everything in the host's primary connection (the escape
    # hatch). Set via Rbrun.config.database_connection in the host initializer, before models load.
    conn = Rbrun.config.database_connection
    connects_to database: { writing: conn, reading: conn } if conn && conn != :primary
  end
end
