module Rbrun
  module Ui
    module Dialog
      # The single, app-wide centered modal. A native <dialog> whose body is a <turbo-frame id="modal">.
      # Render once in the layout via component("dialog"). Any link with data: { turbo_frame: "modal" }
      # loads its response into the frame; the shared `overlay` controller opens/closes it (open when the
      # frame gains content, close when emptied). Faithfully ported from ../insitix (Primitives::Dialog).
      # Honors prefers-reduced-motion.
      class Component < Rbrun::ApplicationViewComponent
        # BARE shell: positioning + backdrop + animation + the max-h that constrains scrolling. Chrome
        # (rounded/border/bg/shadow) now lives on the Ui::Surface streamed into #modal. `flex flex-col`
        # + a flex-passthrough #modal frame carry the height bound down so the SURFACE BODY scrolls (not
        # the shell). `w-fit`, NOT `w-auto`: the UA gives a modal <dialog> width:fit-content; w-auto with
        # both inset edges at 0 would fill the width (a full-width slab). The <dialog> still wraps the
        # surface, so a backdrop click resolving to this element still closes.
        CLASSES = %w[
          m-auto flex w-fit min-w-[20rem] max-w-[92vw] max-h-[90dvh] flex-col bg-transparent p-0
          opacity-0 scale-95 transition duration-200 ease-out motion-reduce:transition-none
          data-[open]:opacity-100 data-[open]:scale-100
          backdrop:bg-slate-950/0 backdrop:transition-colors backdrop:duration-200 backdrop:ease-out
          data-[open]:backdrop:bg-slate-950/40
        ].freeze

        def call
          tag.dialog(
            tag.turbo_frame(nil, id: "modal", class: "flex min-h-0 min-w-0 flex-auto flex-col"),
            class: class_names(CLASSES),
            data: { controller: "overlay", action: "cancel->overlay#cancel click->overlay#backdropClose" }
          )
        end
      end
    end
  end
end
