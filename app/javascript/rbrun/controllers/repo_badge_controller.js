import { Controller } from "@hotwired/stimulus"

// Lives on the composer's RepoBadge. Consumes a client-side pick (window "rbrun:repo-selected") and
// writes it into the compose form's hidden repo/base fields; the ✕ clears them. No global scope.
export default class extends Controller {
  static targets = ["repo", "base", "label", "clear"]

  connect() {
    this.onSelect = this.onSelect.bind(this)
    window.addEventListener("rbrun:repo-selected", this.onSelect)
  }

  disconnect() {
    window.removeEventListener("rbrun:repo-selected", this.onSelect)
  }

  onSelect(event) {
    const { repo, base } = event.detail
    this.repoTarget.value = repo
    this.baseTarget.value = base || ""
    this.labelTarget.textContent = repo
    this.clearTarget.classList.remove("hidden")
  }

  clear(event) {
    event.preventDefault()
    this.repoTarget.value = ""
    this.baseTarget.value = ""
    this.labelTarget.textContent = "Select a repository"
    this.clearTarget.classList.add("hidden")
  }
}
