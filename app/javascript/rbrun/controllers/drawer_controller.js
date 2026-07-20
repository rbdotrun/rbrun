import { Controller } from "@hotwired/stimulus"

// A slide-over drawer (the service logs view). Closing clears the layout's #service_drawer slot and
// closes on Escape. Purely client-side.
export default class extends Controller {
  connect() {
    this._onKey = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this._onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKey)
  }

  close() {
    const slot = document.getElementById("service_drawer")
    if (slot) slot.innerHTML = ""
  }
}
