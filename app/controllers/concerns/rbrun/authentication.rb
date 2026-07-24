module Rbrun
  # Mandatory auth: every engine controller requires a signed-in user. current_tenant is the user's
  # tenant slug. A host may supply its own auth via Rbrun.current_user_resolver (given the session).
  module Authentication
    extend ActiveSupport::Concern

    included do
      before_action :require_authentication
      helper_method :current_user, :current_tenant
    end

    private

      # ONE authority per deployment, decided by which seam is installed — never an `||` across both.
      #
      # Rbrun.current_user_from returns nil in two OPPOSITE situations: no host resolver is configured,
      # and the host resolver says "this person is not signed in". OR-ing past it treated a rejection as
      # an absence and fell through to rbrun's own password form + session[:rbrun_user_id] cookie — so
      # in a host-auth deployment, someone the host had logged out (or never authorized) could still get
      # in through the built-in login, carrying their own tenant into every for_tenant query.
      def current_user
        return @current_user if defined?(@current_user)

        @current_user =
          if Rbrun.host_auth?
            Rbrun.current_user_from(session) # the host owns identity, verdict included
          else
            session[:rbrun_user_id] && Rbrun::User.find_by(id: session[:rbrun_user_id])
          end
      end

      def current_tenant = current_user&.tenant

      def require_authentication
        redirect_to rbrun.login_path unless current_user
      end

      def establish_session(user) = session[:rbrun_user_id] = user.id
      def reset_authentication = session.delete(:rbrun_user_id)
  end
end
