module Rbrun
  class ApplicationController < ActionController::Base
    # Make the component("name", …) string-render helper available in every engine view.
    helper Rbrun::ComponentHelper
  end
end
