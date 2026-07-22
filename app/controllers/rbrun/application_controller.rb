module Rbrun
  class ApplicationController < ActionController::Base
    include Rbrun::Authentication

    # Make the component() + session helpers + lucide icons available in every engine view.
    helper Rbrun::ComponentHelper
    helper Rbrun::SessionsHelper
    helper LucideRails::RailsHelper

    layout "rbrun/application"

    private

    # A <turbo-frame src="…"> fetch sends Accept: text/vnd.turbo-frame.html. Turbo registers no Rails
    # format symbol for it (only :turbo_stream exists), so detect the header directly. Use it to render
    # layout-less for frame requests — the response then holds ONLY the requested <turbo-frame>, not the
    # full layout. Otherwise the layout would re-include another frame with the same id (e.g. the repo
    # switcher's own #repo_results), and Turbo extracts the FIRST match — the wrong one.
    def turbo_frame_request?
      request.headers["Accept"].to_s.include?("text/vnd.turbo-frame.html")
    end
  end
end
