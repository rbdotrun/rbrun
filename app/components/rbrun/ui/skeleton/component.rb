module Rbrun
  module Ui
    module Skeleton
      # A shimmer placeholder shown while real content streams into a Turbo frame (e.g. the repo
      # switcher's lazy #repo_results). `variant` picks WHAT is being skeletonized — the preset for the
      # row shape. Today :list_item (avatar + two stacked lines, mirroring Ui::ListItem); future shapes
      # (:table, …) add a private *_row builder + a `when` here. `rows` = how many rows to draw.
      # animate-pulse does the shimmer; it's aria-hidden (a transient placeholder, not content).
      class Component < Rbrun::ApplicationViewComponent
        option :variant, default: proc { :list_item }
        option :rows, default: proc { 6 }
        option :css, optional: true

        BAR = "animate-pulse rounded bg-slate-100".freeze

        def call
          tag.div(role: "presentation", aria: { hidden: "true", busy: "true" },
                  class: cn("p-1", css)) do
            safe_join(Array.new(rows.to_i) { row })
          end
        end

        private

        def row
          case variant.to_sym
          when :list_item then list_item_row
          else list_item_row
          end
        end

        # Mirrors an Ui::ListItem row: avatar square + two stacked text bars.
        def list_item_row
          tag.div(class: "flex items-center gap-2.5 rounded-md px-2.5 py-1.5") do
            safe_join([
              tag.div(class: cn("size-9 shrink-0", BAR)),
              tag.div(class: "flex min-w-0 flex-1 flex-col gap-1.5") do
                safe_join([
                  tag.div(class: cn("h-3.5 w-40 max-w-full", BAR)),
                  tag.div(class: cn("h-2.5 w-24 max-w-full", BAR))
                ])
              end
            ])
          end
        end
      end
    end
  end
end
