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

    # Re-launch the repo's saved services (the panel's "Restart all") in this worktree.
    def restart_saved
      saved = Rbrun::RepoService.for_tenant(@worktree.tenant).for_repo(@worktree.repo)
      start(saved.map { |s| { "name" => s.name, "command" => s.command, "port" => s.port } })
    end

    private

    def normalize(services)
      Array(services).map do |s|
        s = s.transform_keys(&:to_s)
        Service.new(s["name"].to_s.strip, s["command"].to_s.strip, s["port"].presence&.to_i)
      end.reject { |s| s.name.empty? || s.command.empty? }
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
      @sup.launch(run)
      resolve_preview(run)
    end

    # A port-bearing service gets its preview URL — only when the provider supports it (graceful degrade
    # on a proxy-less sandbox: it still runs + logs, just no Open).
    def resolve_preview(run)
      return run unless run.port.present? && @worktree.previews_supported?

      link = @worktree.sandbox.preview_url(run.port)
      run.update!(url: link.url, token: link.token)
      run
    end

    def find(name) = @worktree.service_runs.find_by(name: name)
  end
end
