class AddPreviewedToRbrunRepoServices < ActiveRecord::Migration[8.1]
  def change
    # Durable, declarative intent: is this repo service exposed for preview? Lives on the DEFINITION, not
    # the run — repo_services_start is a reset that recreates runs, so a per-run flag would be lost.
    add_column :rbrun_repo_services, :previewed, :boolean, null: false, default: false
  end
end
