import { Turbo } from "@hotwired/turbo-rails"

// App-wide confirm override: EVERY confirmation — declarative data-turbo-confirm (deletes, logout)
// and programmatic Turbo.config.forms.confirm callers — routes through our styled <dialog
// id="confirm-dialog"> instead of the browser's window.confirm. One override, no per-call wiring.
// Faithfully ported from ../insitix.
const EXIT_MS = 160

const confirm = (message) => {
  const dialog = document.getElementById("confirm-dialog")
  if (!dialog) return Promise.resolve(window.confirm(message)) // safety net

  dialog.querySelector("[data-confirm-message]").textContent = message
  const accept = dialog.querySelector("[data-confirm-accept]")
  const cancel = dialog.querySelector("[data-confirm-cancel]")

  dialog.showModal()
  requestAnimationFrame(() => dialog.setAttribute("data-open", "")) // enter

  return new Promise((resolve) => {
    // Play the exit transition, then close with a return value.
    const settle = (value) => {
      dialog.removeAttribute("data-open")
      window.setTimeout(() => dialog.close(value), EXIT_MS)
    }
    accept.onclick = () => settle("accept")
    cancel.onclick = () => settle("cancel")
    dialog.onclick = (event) => { if (event.target === dialog) settle("cancel") } // backdrop

    // Fires on button close AND on ESC (returnValue === "" → cancelled). Clears data-open so the
    // next open re-animates.
    dialog.addEventListener("close", () => {
      dialog.removeAttribute("data-open")
      resolve(dialog.returnValue === "accept")
    }, { once: true })
  })
}

if (Turbo.config?.forms) Turbo.config.forms.confirm = confirm
else if (Turbo.setConfirmMethod) Turbo.setConfirmMethod(confirm)
