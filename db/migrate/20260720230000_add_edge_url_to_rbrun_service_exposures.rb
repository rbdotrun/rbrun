class AddEdgeUrlToRbrunServiceExposures < ActiveRecord::Migration[8.1]
  def change
    # When the HOST owns the edge (Rbrun.preview_edge set — the control plane), it returns the preview URL
    # from #expose; we store it here. nil in self-host, where the URL is derived from the preview_token.
    add_column :rbrun_service_exposures, :edge_url, :string
  end
end
