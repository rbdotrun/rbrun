module Rbrun
  module Ui
    module ConfirmDialog
      # The single, app-wide confirmation modal. A native <dialog id="confirm-dialog"> driven by Turbo's
      # confirm hook (turbo_confirm.js) — every data-turbo-confirm and every Turbo.config.forms.confirm
      # caller routes through it instead of the browser's window.confirm. Render once in the layout via
      # component("confirm_dialog"). Faithfully ported from ../insitix (Primitives::ConfirmDialog).
      class Component < Rbrun::ApplicationViewComponent
        CLASSES = %w[
          m-auto w-full max-w-sm rounded-xl border border-slate-200 bg-white p-0 text-slate-800 shadow-xl
          opacity-0 scale-95 transition duration-200 ease-out motion-reduce:transition-none
          data-[open]:opacity-100 data-[open]:scale-100
          backdrop:bg-slate-950/0 backdrop:transition-colors backdrop:duration-200 backdrop:ease-out
          data-[open]:backdrop:bg-slate-950/40
        ].freeze

        def classes = CLASSES.join(" ")
      end
    end
  end
end
