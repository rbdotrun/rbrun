// Shared open/close animation for native <dialog>s (Ui::Drawer + Ui::Dialog). The dialog transitions
// on a `data-open` attribute (the component's Tailwind defines opacity/scale/backdrop for [data-open]).
// Enter: showModal(), then flip data-open one frame later so the from-state paints. Exit: remove
// data-open, wait for the transition, THEN close() — otherwise the dialog vanishes with no outro.
// Faithfully ported from ../insitix.
const EXIT_MS = 250
const closing = new WeakSet()

export function openDialog(dialog) {
  dialog.showModal()
  requestAnimationFrame(() => dialog.setAttribute("data-open", ""))
}

export function closeDialog(dialog) {
  if (closing.has(dialog)) return
  closing.add(dialog)
  dialog.removeAttribute("data-open")

  const done = () => {
    closing.delete(dialog)
    if (dialog.open) dialog.close()
  }
  dialog.addEventListener("transitionend", done, { once: true })
  setTimeout(done, EXIT_MS) // fallback: reduced motion / interrupted transition
}
