import { Controller } from "@hotwired/stimulus"

// Collapse/expand the task-progress band. Client-only: the open/closed choice persists in a cookie and
// is re-applied on connect, so a live band re-render (broadcast_workflow) keeps the user's preference
// without the server ever reading the cookie (broadcasts render without a request).
export default class extends Controller {
  static targets = ["body", "chevron"]

  connect() {
    this.apply(this.expanded())
  }

  toggle() {
    const open = !this.expanded()
    document.cookie = `workflow_expanded=${open ? "1" : ""}; path=/; max-age=${open ? 31536000 : 0}`
    this.apply(open)
  }

  apply(open) {
    this.bodyTarget.classList.toggle("hidden", !open)
    if (this.hasChevronTarget) this.chevronTarget.classList.toggle("rotate-180", open)
  }

  expanded() {
    return document.cookie.split("; ").includes("workflow_expanded=1")
  }
}
