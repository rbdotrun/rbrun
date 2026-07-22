module Rbrun
  module Ui
    module DialogFrame
      # The CONTENT of the app-wide modal: the <turbo-frame id="modal"> a trigger loads into, wrapped in
      # a padded panel with an optional title + description. Every modal view renders THROUGH this so
      # headers read the same everywhere — component("dialog_frame", title: "…") { body }. Faithfully
      # ported from ../insitix (Primitives::DialogFrame).
      class Component < Rbrun::ApplicationViewComponent
        def initialize(title: nil, description: nil)
          @title = title
          @description = description
        end

        attr_reader :title, :description
      end
    end
  end
end
