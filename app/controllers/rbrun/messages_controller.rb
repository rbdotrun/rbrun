module Rbrun
  class MessagesController < Rbrun::ApplicationController
    before_action :set_session

    # The composer POSTs here. Enqueue the turn (a JOB — never inline) and reset the composer. The
    # user message is appended to the timeline by the model's broadcast callback, not here.
    def create
      content = params.dig(:message, :content)
      return head(:bad_request) if content.blank?

      AgentTurnJob.perform_later(@session.id, content.to_s)

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to rbrun.session_path(@session) }
      end
    end

    private

    def set_session = @session = Rbrun::Session.for_tenant(current_tenant).find(params[:id])
  end
end
