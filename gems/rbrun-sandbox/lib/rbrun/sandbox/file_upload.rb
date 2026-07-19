# frozen_string_literal: true

module Rbrun
  module Sandbox
    # One file to put in a box: where it comes from here (a local path or an IO), where it goes there.
    FileUpload = Data.define(:source, :destination)
  end
end
