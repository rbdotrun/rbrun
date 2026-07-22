import { Controller } from "@hotwired/stimulus"
import { openDialog, closeDialog } from "./dialog_animation"

// Drives a native <dialog> whose body is a single <turbo-frame>. Trigger links
// (data-turbo-frame="<id>") load content into the frame; we open the dialog when the frame gains
// content and close when emptied (a turbo_stream clears the frame after a submit, or the close button
// / Esc / backdrop). Shared by Ui::Drawer and Ui::Dialog — only CSS + frame id differ, so the frame is
// looked up generically. Faithfully ported from ../insitix.
export default class extends Controller {
  connect() {
    this.frame = this.element.querySelector("turbo-frame")
    this.observer = new MutationObserver(() => this.sync())
    this.observer.observe(this.frame, { childList: true })
    this.sync()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  sync() {
    const filled = this.frame.children.length > 0
    if (filled && !this.element.open) openDialog(this.element)
    else if (!filled && this.element.open) closeDialog(this.element)
  }

  close() {
    this.frame.replaceChildren()
  }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  backdropClose(event) {
    if (event.target === this.element) this.close()
  }
}
