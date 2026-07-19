module Rbrun
  module Auth
    # Login/logout against rbrun's own User (has_secure_password). No session ⇒ everything else
    # redirects here (see Rbrun::Authentication).
    class SessionsController < Rbrun::ApplicationController
      layout "rbrun/auth"
      skip_before_action :require_authentication, only: %i[new create]

      def new; end

      def create
        user = Rbrun::User.find_by(email: params[:email].to_s.strip.downcase)
        if user&.authenticate(params[:password].to_s)
          establish_session(user)
          redirect_to rbrun.sessions_path
        else
          @error = "Invalid credentials."
          render :new, status: :unprocessable_entity
        end
      end

      def destroy
        reset_authentication
        redirect_to rbrun.login_path
      end
    end
  end
end
