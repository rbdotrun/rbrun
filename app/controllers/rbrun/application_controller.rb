module Rbrun
  class ApplicationController < ActionController::Base
    include Rbrun::Authentication

    # Make the component() + session helpers + lucide icons available in every engine view.
    helper Rbrun::ComponentHelper
    helper Rbrun::SessionsHelper
    helper LucideRails::RailsHelper

    layout "rbrun/application"
  end
end
