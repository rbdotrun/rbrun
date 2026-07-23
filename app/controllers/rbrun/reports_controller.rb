module Rbrun
  # Per-turn "report an error". `new` renders the report dialog into the app-wide #modal; `create` files
  # the report and streams the footer back as "Reported" (and closes the modal). One report per turn.
  class ReportsController < Rbrun::ApplicationController
    before_action :set_turn

    def new
      render :new, layout: false
    end

    def create
      Rbrun::TurnReport.find_or_create_by!(tenant: current_tenant, session: @session, user_message: @lead) do |r|
        r.comment = params[:comment].to_s.strip.presence
      end
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to rbrun.session_path(@session) }
      end
    end

    private

    def set_turn
      @session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
      @lead = @session.messages.find(params[:message_id])
    end
  end
end
