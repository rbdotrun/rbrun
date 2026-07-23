module Rbrun
  module Ui
    module Drawer
      # The single, app-wide right slide-over. A native <dialog> whose body is a <turbo-frame id="drawer">.
      # Render once in the layout via component("drawer"). Any link with data: { turbo_frame: "drawer" }
      # loads its response into the frame; the shared `overlay` controller opens/closes it. Faithfully
      # ported from ../insitix (Primitives::Drawer). Honors prefers-reduced-motion.
      class Component < Rbrun::ApplicationViewComponent
        # BARE right-anchored shell: fixed position + slide animation + backdrop + h-dvh (the height
        # bound). Chrome (rounded-none/border-l/bg/shadow) now lives on the :drawer Surface streamed into
        # #drawer. `flex flex-col` + a flex-passthrough frame carry the height down so the SURFACE BODY
        # scrolls (not the shell).
        CLASSES = %w[
          fixed inset-y-0 right-0 left-auto m-0 flex h-dvh w-full max-w-[760px] flex-col bg-transparent p-0
          translate-x-full transition duration-200 ease-out motion-reduce:transition-none
          data-[open]:translate-x-0
          backdrop:bg-slate-950/0 backdrop:transition-colors backdrop:duration-200 backdrop:ease-out
          data-[open]:backdrop:bg-slate-950/40
          max-h-dvh min-h-0 min-w-0 overflow-hidden
        ].freeze

        def call
          tag.dialog(
            tag.turbo_frame(nil, id: "drawer", class: "flex min-h-0 min-w-0 flex-auto flex-col"),
            class: class_names(CLASSES),
            data: { controller: "overlay", action: "cancel->overlay#cancel click->overlay#backdropClose" }
          )
        end
      end
    end
  end
end
