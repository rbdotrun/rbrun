require "shellwords"

module Rbrun
  # Owns the SANDBOX-LEVEL mechanics of a service — env injection, launch under a managed process session
  # (pidfile-stoppable), stop, and status. It sits behind the tool contract so a future systemd/compose
  # backend is a single swap and neither the tools nor the UI change. v1 = managed sessions + pidfiles.
  #
  # Secret env is written to <workspace>/.rbrun/env (0600) and sourced by the launch wrapper: the values
  # reach the sandbox (the app needs them) but never the conversation/LLM.
  class ServiceSupervisor
    def initialize(worktree:)
      @worktree = worktree
      @sandbox  = worktree.sandbox
    end

    # Materialize the repo's secrets into a 0600 env file the launch wrapper sources.
    def write_env!
      secrets = Rbrun::RepoSecret.for_tenant(@worktree.tenant).for_repo(@worktree.repo)
      body = secrets.map { |s| "export #{s.key}=#{Shellwords.escape(s.value.to_s)}" }.join("\n")
      script = "mkdir -p #{ws}/.rbrun && (umask 177; cat > #{ws}/.rbrun/env) <<'RBRUN_ENV'\n#{body}\nRBRUN_ENV"
      @sandbox.exec("sh -c #{Shellwords.escape(script)}")
    end

    # Start run.command as a managed session: cd into the workspace, source the secret env, record the
    # pid (pidfile ⇒ stoppable independent of the transport), then exec the command in place.
    def launch(run)
      sess = session_name(run)
      @sandbox.session_create(sess)
      wrapped = "cd #{ws} && mkdir -p .rbrun && set -a; [ -f .rbrun/env ] && . .rbrun/env; set +a; " \
                "echo $$ > .rbrun/#{pidfile(run)}; exec #{run.command}"
      cmd_id = @sandbox.session_exec(sess, "sh -c #{Shellwords.escape(wrapped)}")
      run.update!(process_session: sess, cmd_id: cmd_id, status: "running", exit_code: nil, log_offset: 0)
      run
    end

    # Kill by pidfile (plain exec, universal to every adapter). Idempotent.
    def stop(run)
      @sandbox.exec("sh -c #{Shellwords.escape("kill $(cat #{ws}/.rbrun/#{pidfile(run)} 2>/dev/null) 2>/dev/null; true")}")
      run.update!(status: "stopped")
      run
    end

    # Recent output of a service. A live server never closes its stream, so follow with a short bounded
    # window and return the trailing `lines`. Shared by repo_services_logs and the Logs drawer.
    def tail(run, lines: 200)
      return "" if run.process_session.blank? || run.cmd_id.blank?

      out = +""
      begin
        @sandbox.session_logs_follow(run.process_session, run.cmd_id, skip: 0, timeout: 3) { |chunk| out << chunk; false }
      rescue Rbrun::Sandbox::TimeoutError
        # bounded read — a live service never closes the stream; return what accumulated.
      rescue StandardError
        # best-effort: a stale/missing handle (sandbox gone, session reaped) reads as no output, never a crash.
      end
      out.lines.last(lines.to_i.clamp(1, 5000)).join
    end

    # A present exitCode ⇒ the process ended. Cheap; called on panel load / status / recheck.
    def refresh_status(run)
      return run if run.status_stopped? || run.cmd_id.blank? || run.process_session.blank?

      info = @sandbox.session_command(run.process_session, run.cmd_id)
      code = info.is_a?(Hash) ? (info["exitCode"] || info["exit_code"]) : nil
      run.update!(status: "exited", exit_code: code.to_i) unless code.nil?
      run
    end

    private

    def ws = @sandbox.workspace
    def session_name(run) = "svc-#{@worktree.id}-#{run.name}"
    def pidfile(run) = "svc-#{run.name}.pid"
  end
end
