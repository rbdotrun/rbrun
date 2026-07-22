import { Controller } from "@hotwired/stimulus"

// A styled file picker + drop target for fields that save with the SURROUNDING form (not auto-
// submitting). Highlights on drag, writes dropped files into the hidden input, and lists the picked
// filenames as chips. Faithfully ported from ../insitix.
export default class extends Controller {
  static targets = ["input", "zone", "preview"]
  static classes = ["dragover"]

  dragover(event) {
    event.preventDefault()
    if (this.hasDragoverClass) this.zoneTarget.classList.add(...this.dragoverClasses)
  }

  dragleave() {
    if (this.hasDragoverClass) this.zoneTarget.classList.remove(...this.dragoverClasses)
  }

  drop(event) {
    event.preventDefault()
    this.dragleave()
    this.inputTarget.files = event.dataTransfer.files
    this.selected()
  }

  selected() {
    if (!this.hasPreviewTarget) return
    const files = Array.from(this.inputTarget.files || [])
    this.previewTarget.replaceChildren(...files.map((file) => this.chip(file.name)))
    this.previewTarget.hidden = files.length === 0
  }

  chip(name) {
    const li = document.createElement("li")
    li.className =
      "inline-flex max-w-full items-center gap-1 rounded-md bg-default-50 px-2 py-1 " +
      "text-xs font-medium text-default-700 ring-1 ring-inset ring-default-600/15"
    const label = document.createElement("span")
    label.className = "truncate"
    label.textContent = name
    li.append(label)
    return li
  }
}
