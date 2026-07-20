module Rbrun
  # Orchestrates the repo_services_* operations over a worktree: the idempotent start (kill-all →
  # upsert the saved set → launch fresh → resolve previews), plus restart/stop/status/restart_saved.
  # Delegates the sandbox mechanics to ServiceSupervisor; owns the DB rows (RepoService saved,
  # ServiceRun live) and preview resolution.
  class ServiceLauncher
    Service = Data.define(:name, :command, :port)

    def initialize(worktree:)
      @worktree = worktree
      @sup = Rbrun::ServiceSupervisor.new(worktree: worktree)
    end

    # Idempotent reset ("kill all and restart"): stop+clear every run, upsert the repo's saved set, write
    # the secret env once, launch each fresh, resolve previews. Re-running always converges.
    def start(services)
      list = normalize(services)
      stop_all
      upsert_saved(list)
      @sup.write_env!
      list.map { |svc| launch_one(svc) }
    end

    # Surgical stuck-recovery: kill one and start it again from its saved command.
    def restart(name)
      run = find(name) or return nil
      @sup.stop(run)
      @sup.launch(run)
      resolve_preview(run)
    end

    def stop(name: nil)
      (name ? [ find(name) ].compact : @worktree.service_runs.to_a).each { |r| @sup.stop(r) }
    end

    def status = @worktree.service_runs.map { |r| @sup.refresh_status(r) }

    # ── preview: a SEPARATE, declarative, reversible decision (never implied by starting) ──────────
    # Declare a service previewed and resolve its URL now. Returns the run, or an error symbol:
    # :unknown (no such service) · :no_port (declares no port) · :unsupported (provider can't preview).
    def preview(name)
      definition = saved(name)
      run = find(name)
      return :unknown unless definition || run
      return :no_port if (run&.port || definition&.port).blank?
      return :unsupported unless @worktree.previews_supported?

      definition&.update!(previewed: true)
      run ? resolve_preview(run) : :not_running
    end

    # Withdraw the declaration and forget the resolved link. CASCADES to level 3: you cannot remain
    # publicly shared while not previewed.
    def stop_preview(name)
      definition = saved(name)
      run = find(name)
      return :unknown unless definition || run

      stop_sharing(name)
      definition&.update!(previewed: false)
      run&.update!(url: nil, token: nil)
      run || :not_running
    end

    # ── level 3: public. STRICTLY requires level 2 — the state (public && !previewed) is unreachable. ──
    # Returns the share, or :unknown · :not_running · :not_previewed.
    def share_public(name)
      run = find(name)
      return :unknown unless run || saved(name)
      return :not_running unless run&.status_running?
      return :not_previewed unless run.url.present? && saved(name)&.previewed?

      @worktree.public_shares.find_or_create_by!(name: name)
    end

    # Revoke the public link. Always safe, hence ungated everywhere.
    def stop_sharing(name)
      @worktree.public_shares.where(name: name).destroy_all
      true
    end

    def share_for(name) = @worktree.public_shares.find_by(name: name)

    # Re-launch the repo's saved services (the panel's "Restart all") in this worktree.
    def restart_saved
      saved = Rbrun::RepoService.for_tenant(@worktree.tenant).for_repo(@worktree.repo)
      start(saved.map { |s| { "name" => s.name, "command" => s.command, "port" => s.port } })
    end

    private

    def normalize(services)
      Array(services).filter_map { |s| coerce_service(s) }.reject { |s| s.name.empty? || s.command.empty? }
    end

    # Tolerate a stray String element (a JSON blob) as well as a Hash — the client schema should send
    # objects, but never crash the start on a malformed element.
    def coerce_service(raw)
      raw = (JSON.parse(raw) rescue nil) if raw.is_a?(String)
      return nil unless raw.is_a?(Hash)

      s = raw.transform_keys(&:to_s)
      Service.new(s["name"].to_s.strip, s["command"].to_s.strip, s["port"].presence&.to_i)
    end

    def stop_all
      @worktree.service_runs.each { |r| @sup.stop(r) }
      @worktree.service_runs.destroy_all
    end

    def upsert_saved(list)
      list.each_with_index do |svc, i|
        rec = Rbrun::RepoService.for_tenant(@worktree.tenant).find_or_initialize_by(repo: @worktree.repo, name: svc.name)
        rec[Rbrun.config.tenancy_key] = @worktree.tenant
        rec.update!(command: svc.command, port: svc.port, position: i)
      end
    end

    def launch_one(svc)
      run = @worktree.service_runs.create!(name: svc.name, command: svc.command, port: svc.port, status: "starting")
      begin
        @sup.launch(run)
      rescue StandardError
        # Never leave a zombie row (status "starting", no process handle) — it makes logs/restart
        # report nonsense for a service that was never actually launched.
        run.destroy
        raise
      end
      # Starting a service NEVER exposes it. A URL is resolved only when the service was already
      # DECLARED previewed (RepoService#previewed) — honouring a prior explicit decision, never implying
      # one. A port is just what the process binds to inside the box.
      declared_previewed?(svc.name) ? resolve_preview(run) : run
    end

    def declared_previewed?(name) = saved(name)&.previewed?

    # Resolve the provider's preview URL for a running, port-bearing service. Only ever called for a
    # service explicitly declared previewed.
    def resolve_preview(run)
      return run unless run.port.present? && @worktree.previews_supported?

      link = @worktree.sandbox.preview_url(run.port)
      run.update!(url: link.url, token: link.token)
      run
    rescue StandardError => e
      # A preview hiccup must not fail the service start — it still runs and logs, just without an Open.
      Rails.logger.warn("[rbrun] preview_url(#{run.port}) failed: #{e.message}")
      run
    end

    def find(name) = @worktree.service_runs.find_by(name: name)

    def saved(name)
      Rbrun::RepoService.for_tenant(@worktree.tenant).for_repo(@worktree.repo).find_by(name: name)
    end
  end
end
