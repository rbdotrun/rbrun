import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Self-contained single-file control (logo, banner, avatar): the thumbnail IS the click/drop target.
// Picking a file previews it instantly; the inline clear button flips a hidden remove_* input to "1"
// (model purges on save). Saves with the surrounding form — it does not submit on its own. Faithfully
// ported from ../insitix.
export default class extends Controller {
  static targets = ["input", "preview", "placeholder", "filename", "clear", "removeInput"]
  static classes = ["dragover"]

  trigger(event) {
    if (event.target.closest("[data-single-upload-target='clear']")) return
    this.inputTarget.click()
  }

  selected() {
    const file = this.inputTarget.files?.[0]
    if (!file) return
    if (this.hasRemoveInputTarget) this.removeInputTarget.value = "0"
    this.showImage(URL.createObjectURL(file))
    this.filenameTarget.textContent = file.name
    this.reveal(this.clearTarget)
  }

  async clear(event) {
    event.preventDefault()
    event.stopPropagation()
    const ask = Turbo.config?.forms?.confirm ?? window.confirm
    if (!(await ask(this.clearTarget.dataset.confirm || "Remove this file?", this.element))) return
    this.inputTarget.value = ""
    if (this.hasRemoveInputTarget) this.removeInputTarget.value = "1"
    this.hideImage()
    this.filenameTarget.textContent = this.filenameTarget.dataset.default || ""
    this.hide(this.clearTarget)
  }

  dragover(event) {
    event.preventDefault()
    if (this.hasDragoverClass) this.element.classList.add(...this.dragoverClasses)
  }

  dragleave() {
    if (this.hasDragoverClass) this.element.classList.remove(...this.dragoverClasses)
  }

  drop(event) {
    event.preventDefault()
    this.dragleave()
    this.inputTarget.files = event.dataTransfer.files
    this.selected()
  }

  showImage(src) {
    this.previewTarget.src = src
    this.reveal(this.previewTarget)
    if (this.hasPlaceholderTarget) this.hide(this.placeholderTarget)
  }

  hideImage() {
    this.previewTarget.removeAttribute("src")
    this.hide(this.previewTarget)
    if (this.hasPlaceholderTarget) this.reveal(this.placeholderTarget)
  }

  reveal(el) { el.classList.remove("hidden") }
  hide(el) { el.classList.add("hidden") }
}
