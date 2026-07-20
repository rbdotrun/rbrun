module Rbrun
  # Orchestrates the repo_services_* operations over a worktree: the idempotent start (kill-all →
  # upsert the saved set → launch fresh), plus restart/stop/status, and the exposure ladder
  # (preview / share_public). Delegates sandbox mechanics to ServiceSupervisor.
  #
  # Exposure intent lives on ServiceExposure (per [worktree, name], survives the start-reset). Levels are
  # served by the ENGINE's own edge (Rbrun::PreviewProxy): starting resolves the sandbox's provider URL
  # onto the ServiceRun as the proxy's UPSTREAM; the human-facing URL is the exposure's preview host. The
  # sandbox is never made provider-public.
  class ServiceLauncher
    Service = Data.define(:name, :command, :port)

    def initialize(worktree:)
      @worktree = worktree
      @sup = Rbrun::ServiceSupervisor.new(worktree: worktree)
    end

    # Idempotent reset ("kill all and restart"): stop+clear every run, upsert the saved set, write the
    # secret env once, launch each fresh (re-resolving upstream for a still-previewed service).
    def start(services)
      list = normalize(services)
      stop_all
      upsert_saved(list)
      @sup.write_env!
      list.map { |svc| launch_one(svc) }
    end

    def restart(name)
      run = find(name) or return nil
      @sup.stop(run)
      @sup.launch(run)
      resolve_upstream(run) if exposure(name)&.previewed?
      run
    end

    def stop(name: nil)
      (name ? [ find(name) ].compact : @worktree.service_runs.to_a).each { |r| @sup.stop(r) }
    end

    def status = @worktree.service_runs.map { |r| @sup.refresh_status(r) }

    # ── level 2: preview — a SEPARATE, declarative, reversible decision (never implied by starting) ────
    # Returns the ServiceExposure, or :unknown · :no_port · :unsupported · :not_running.
    def preview(name)
      run = find(name)
      return :unknown unless run || saved(name)
      return :no_port if (run&.port || saved(name)&.port).blank?
      return :unsupported unless @worktree.previews_supported?

      exp = exposure!(name)
      exp.update!(previewed: true)
      exp.ensure_preview_token!
      resolve_upstream(run) if run # the proxy's upstream — NOT the user-facing URL
      exp
    end

    # Withdraw preview; CASCADES to level 3 (public requires previewed).
    def stop_preview(name)
      exp = exposure(name)
      run = find(name)
      return :unknown unless exp || run

      stop_sharing(name)
      exp&.update!(previewed: false)
      run&.update!(url: nil, token: nil)
      exp || :not_running
    end

    # ── level 3: public — anyone with the link, no account. STRICTLY requires level 2. ────────────────
    # NO provider switch: the engine's own edge serves it, so the box stays private. Returns the
    # exposure, or :unknown · :not_running · :not_previewed.
    def share_public(name)
      run = find(name)
      exp = exposure(name)
      return :unknown unless run || exp
      return :not_running unless run&.status_running?
      return :not_previewed unless exp&.previewed? && run.url.present?

      exp.update!(shared_public: true)
      exp
    end

    # Revoke. Always safe, hence ungated everywhere.
    def stop_sharing(name)
      exposure(name)&.update!(shared_public: false)
      true
    end

    def previewed?(name) = !!exposure(name)&.previewed?
    def shared?(name)    = !!exposure(name)&.shared_public?
    def exposure(name)   = @worktree.service_exposures.find_by(name: name)

    def restart_saved
      set = Rbrun::RepoService.for_tenant(@worktree.tenant).for_repo(@worktree.repo)
      start(set.map { |s| { "name" => s.name, "command" => s.command, "port" => s.port } })
    end

    private

    def normalize(services)
      Array(services).filter_map { |s| coerce_service(s) }.reject { |s| s.name.empty? || s.command.empty? }
    end

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
        run.destroy # never leave a zombie row (starting, no process handle)
        raise
      end
      # Starting NEVER exposes. Re-resolve the upstream only for a service ALREADY declared previewed
      # (its exposure survived the reset) — honouring a prior decision, never implying one.
      resolve_upstream(run) if exposure(svc.name)&.previewed?
      run
    end

    # Resolve the sandbox's provider preview URL and stash it on the ServiceRun as the PROXY UPSTREAM (not
    # user-facing). Best-effort: a hiccup must not fail the start.
    def resolve_upstream(run)
      return run unless run.port.present? && @worktree.previews_supported?

      link = @worktree.sandbox.preview_url(run.port)
      run.update!(url: link.url, token: link.token)
      run
    rescue StandardError => e
      Rails.logger.warn("[rbrun] preview_url(#{run.port}) failed: #{e.message}")
      run
    end

    def find(name) = @worktree.service_runs.find_by(name: name)
    def saved(name) = Rbrun::RepoService.for_tenant(@worktree.tenant).for_repo(@worktree.repo).find_by(name: name)
    def exposure!(name) = @worktree.service_exposures.find_or_create_by!(name: name)
  end
end
