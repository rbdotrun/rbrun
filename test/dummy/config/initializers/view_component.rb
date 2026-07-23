# ViewComponent previews re-register their `preview_view_components` route on every routes reload,
# which collides with itself ("Invalid route name, already in use") and forces an app restart after
# each code change. We don't use previews (the primitives smoke test covers rendering), so turn them
# off. Set here (an initializer, after ViewComponent's railtie defines config.view_component and before
# routes are drawn) — NOT in the env file, where config.view_component doesn't exist yet.
Rails.application.config.view_component.show_previews = false
