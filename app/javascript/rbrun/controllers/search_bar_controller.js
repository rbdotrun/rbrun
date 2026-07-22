import { Controller } from "@hotwired/stimulus"

// A search input with our own clear (X) and debounced autosearch — no native chrome, no submit button.
// Typing (debounced) submits the GET form, which targets the results Turbo Frame; clicking X clears the
// field and submits too (so `q=` is dropped from the URL). Faithfully ported from ../insitix.
export default class extends Controller {
  static targets = ["input", "clear"]
  static values = { delay: { type: Number, default: 300 } }

  connect() {
    this.toggle()
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  onInput() {
    this.toggle()
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.submit(), this.delayValue)
  }

  clear() {
    clearTimeout(this.timer)
    this.inputTarget.value = ""
    this.toggle()
    this.submit()
    this.inputTarget.focus()
  }

  submit() {
    const input = this.inputTarget
    // A blank search drops `q=` from the URL: a disabled field is left out of the form data, so blank →
    // clean URL; re-enable immediately (data is already serialized by requestSubmit).
    const blank = input.value.trim() === ""
    if (blank) input.disabled = true
    input.form?.requestSubmit()
    if (blank) input.disabled = false
  }

  toggle() {
    if (this.hasClearTarget) {
      this.clearTarget.classList.toggle("hidden", this.inputTarget.value.trim() === "")
    }
  }
}
