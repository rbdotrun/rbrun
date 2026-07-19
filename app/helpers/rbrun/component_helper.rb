module Rbrun
  # String-render helper: `component("spinner", size: :sm)` → render Rbrun::Ui::Spinner::Component.
  # Nice DX; included in the base component and the engine's views.
  module ComponentHelper
    def component(name, *args, **kwargs, &block)
      klass = "Rbrun::Ui::#{name.to_s.camelize}::Component".constantize
      render(klass.new(*args, **kwargs), &block)
    end
  end
end
