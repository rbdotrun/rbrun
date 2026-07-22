module Rbrun
  module Ui
    module Dialog
      # The single, app-wide centered modal. A native <dialog> whose body is a <turbo-frame id="modal">.
      # Render once in the layout via component("dialog"). Any link with data: { turbo_frame: "modal" }
      # loads its response into the frame; the shared `overlay` controller opens/closes it (open when the
      # frame gains content, close when emptied). Faithfully ported from ../insitix (Primitives::Dialog).
      # Honors prefers-reduced-motion.
      class Component < Rbrun::ApplicationViewComponent
        # The shell does NOT decide how wide a modal is — it shrinks to whatever its content declares
        # (DialogFrame's `width:`). `w-fit`, NOT `w-auto`: the UA gives a modal <dialog>
        # width:fit-content; Tailwind's w-auto emits width:auto, which (with both inset edges at 0)
        # fills available width — every modal would render as a full-width slab. max-w/max-h keep it in
        # the viewport; the panel chrome stays here because the <dialog> IS the panel — that's what makes
        # a backdrop click resolve to this element.
        CLASSES = %w[
          m-auto w-fit min-w-[20rem] max-w-[92vw] max-h-[90dvh] overflow-y-auto
          rounded-xl border bg-white p-0 text-slate-800 shadow-xl
          opacity-0 scale-95 transition duration-200 ease-out motion-reduce:transition-none
          data-[open]:opacity-100 data-[open]:scale-100
          backdrop:bg-slate-950/0 backdrop:transition-colors backdrop:duration-200 backdrop:ease-out
          data-[open]:backdrop:bg-slate-950/40
        ].freeze

        def call
          tag.dialog(
            tag.turbo_frame(nil, id: "modal"),
            class: class_names(CLASSES),
            data: { controller: "overlay", action: "cancel->overlay#cancel click->overlay#backdropClose" }
          )
        end
      end
    end
  end
end
