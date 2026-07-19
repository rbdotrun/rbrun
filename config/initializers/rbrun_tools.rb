# Register the engine's built-in tools. Host apps add theirs with Rbrun.register_tool(MyTool) in
# their own initializer. Runs after autoload so the tool classes are available.
Rails.application.config.to_prepare do
  Rbrun.register_tool(Rbrun::Tools::Identity)
end
