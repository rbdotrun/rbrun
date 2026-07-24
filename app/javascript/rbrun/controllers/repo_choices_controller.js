import { Controller } from "@hotwired/stimulus"

// Wraps the switcher dialog's result rows. A pick dispatches the selection to the composer badge and
// closes the modal — no POST, no global cookie.
export default class extends Controller {
  pick(event) {
    event.preventDefault()
    const el = event.currentTarget
    window.dispatchEvent(new CustomEvent("rbrun:repo-selected", {
      detail: { repo: el.dataset.repo, base: el.dataset.base }
    }))
    const modal = document.getElementById("modal")
    if (modal) modal.replaceChildren() // close the dialog by emptying its frame
  }
}
