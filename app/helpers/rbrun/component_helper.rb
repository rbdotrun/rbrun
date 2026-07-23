module Rbrun
  # String-render helpers, so views read `component("spinner")` / `custom("sessions/default")` instead
  # of `render(Rbrun::Ui::Spinner::Component.new(...))`. Included in the base component and the views.
  # Ported from ../insitix's ComponentHelper (same split: `component` = flat UI primitive under
  # Rbrun::Ui::, `custom`/`preset` = a slash path to a folder component under Rbrun::).
  module ComponentHelper
    # `component("nav_item")` -> Rbrun::Ui::NavItem::Component (a flat UI primitive).
    def component(name, *args, **kwargs, &block)
      klass = "Rbrun::Ui::#{name.to_s.camelize}::Component".constantize
      render(klass.new(*args, **kwargs), &block)
    end

    # `custom("sessions/default")` -> Rbrun::Sessions::Default::Component (a folder component). `preset`
    # is an alias — folder/preset compositions live in the same namespace as every other Rbrun
    # component, so the two are the same resolver. (Titled panels are now the `surface` primitive.)
    def custom(name, *args, **kwargs, &block)
      klass = "Rbrun::#{name.to_s.split("/").map(&:camelize).join("::")}::Component".constantize
      render(klass.new(*args, **kwargs), &block)
    end

    alias preset custom
  end
end
