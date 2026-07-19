require "view_component_contrib"
require "tailwind_merge"
require "dry/initializer"
require "lucide-rails"

module Rbrun
  # The component DSL, migrated from work/insiti. view_component is imported; this reproduces the
  # authoring surface: option/param (Dry::Initializer) + style variants (StyleVariants) +
  # tailwind_merge (css: overrides win) + inline erb_template + the component() helper + Stimulus
  # auto-wiring. No Dry::Effects/current_user, no domain ApplicationHelper (see the spec).
  class ApplicationViewComponent < ViewComponentContrib::Base
    extend Dry::Initializer
    include ViewComponentContrib::StyleVariants
    include Rbrun::ComponentHelper
    include LucideRails::RailsHelper

    # Every resolved class string is tailwind-merged, so later utilities override earlier conflicts.
    style_config.postprocess_with do |classes|
      TailwindMerge::Merger.new.merge(classes.join(" "))
    end

    class << self
      def named
        @named ||= name.sub(/::Component$/, "").underscore.split("/").join("--").tr("_", "-")
      end
    end

    # Combine class fragments (base/variants/css override) and tailwind-merge the RESULT, so a later
    # utility (e.g. a `css:` override) beats an earlier conflicting one. This is what makes `css:` win.
    def cn(*classes) = TailwindMerge::Merger.new.merge(classes.flatten.compact.join(" "))

    # Stimulus identity, derived from the class name (Rbrun::Ui::Drawer::Component → rbrun--ui--drawer).
    def controller_name = self.class.named
    def data_target_key = "#{controller_name}-target"

    def merged_data
      return default_data unless respond_to?(:data) && data.respond_to?(:keys)

      data.merge(**default_data)
    end

    def default_data = { controller: controller_name }
  end
end
