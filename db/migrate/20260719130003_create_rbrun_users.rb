class CreateRbrunUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :rbrun_users do |t|
      t.string Rbrun.config.tenancy_key, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :rbrun_users, :email, unique: true
  end
end
