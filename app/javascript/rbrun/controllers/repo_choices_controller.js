import { Controller } from "@hotwired/stimulus"

// Wraps the switcher dialog's result rows. A pick dispatches the selection to the composer badge and
// closes the modal via the overlay controller's own close (empties #modal → the overlay observer
// animates it shut) — no POST, no global cookie.
export default class extends Controller {
  pick(event) {
    event.preventDefault()
    const el = event.currentTarget
    window.dispatchEvent(new CustomEvent("rbrun:repo-selected", {
      detail: { repo: el.dataset.repo, base: el.dataset.base }
    }))
    const dialog = this.element.closest("dialog")
    const overlay = dialog && this.application.getControllerForElementAndIdentifier(dialog, "overlay")
    if (overlay) overlay.close()
    else document.getElementById("modal")?.replaceChildren()
  }
}
