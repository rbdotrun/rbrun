module Rbrun
  # Mandatory auth: every engine controller requires a signed-in user. current_tenant is the user's
  # tenant slug. A host may supply its own auth via Rbrun.current_user_resolver (given the session).
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :require_authentication
      helper_method :current_user, :current_tenant, :current_repo
    end

    private

      def current_user
        @current_user ||= Rbrun.current_user_from(session) ||
                          (session[:rbrun_user_id] && Rbrun::User.find_by(id: session[:rbrun_user_id]))
      end

      def current_tenant = current_user&.tenant

      # The acting workspace: a GitHub "owner/name", session-backed (no Repo table). Scoped within the
      # tenant — a repo's conversations are the Sessions whose Worktree carries this string.
      def current_repo = session[:rbrun_repo].presence

      # The acting repo's default branch, captured when the repo was picked (from the GitHub result).
      def current_repo_base = session[:rbrun_repo_base].presence

      def require_authentication
        redirect_to rbrun.login_path unless current_user
      end

      def establish_session(user) = session[:rbrun_user_id] = user.id
      def reset_authentication = session.delete(:rbrun_user_id)
  end
end
