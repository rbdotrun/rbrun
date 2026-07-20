class AddPreviewTokenToRbrunRepoServices < ActiveRecord::Migration[8.1]
  def change
    # The single-label handle behind a service's preview host (<token>-preview.<domain>). On the
    # definition, so it is STABLE across the repo_services_start reset — a shared link never rotates.
    add_column :rbrun_repo_services, :preview_token, :string
    add_index  :rbrun_repo_services, :preview_token, unique: true
  end
end
