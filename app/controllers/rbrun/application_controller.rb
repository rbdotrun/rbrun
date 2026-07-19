module Rbrun
  class ApplicationController < ActionController::Base
    include Rbrun::Authentication

    # Make the component() + conversation helpers available in every engine view.
    helper Rbrun::ComponentHelper
    helper Rbrun::ConversationHelper

    layout "rbrun/application"
  end
end
