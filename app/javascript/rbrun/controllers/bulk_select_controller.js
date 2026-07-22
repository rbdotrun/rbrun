// Row selection for a table: a header "select all" checkbox, per-row checkboxes, and a bottom action
// bar that appears while ≥1 row is selected. Purely client-side — the bar's buttons are wired by the
// page. Faithfully ported from ../insitix.
//
// Markup contract:
//   <div data-controller="bulk-select">
//     <input type="checkbox" data-bulk-select-target="all" data-action="change->bulk-select#toggleAll">
//     <input type="checkbox" data-bulk-select-target="checkbox" value="42" data-action="change->bulk-select#toggle">
//     <div data-bulk-select-target="bar" hidden> <span data-bulk-select-target="count">0</span> … </div>
//   </div>
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "all", "bar", "count", "label"]

  connect() {
    this.#sync()
  }

  toggleAll() {
    const checked = this.allTarget.checked
    this.checkboxTargets.forEach((c) => { c.checked = checked })
    this.#sync()
  }

  toggle() {
    this.#sync()
  }

  clear() {
    this.checkboxTargets.forEach((c) => { c.checked = false })
    this.#sync()
  }

  // Generic bulk submit: POST the checked ids to data-url as data-param (default "ids[]"). Builds a
  // throwaway form so no wrapping <form> is needed.
  submit(event) {
    const url = event.currentTarget.dataset.url
    if (!url) return
    const param = event.currentTarget.dataset.param || "ids[]"
    const form = document.createElement("form")
    form.method = "post"
    form.action = url
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    if (token) form.appendChild(this.#hidden("authenticity_token", token))
    this.checkboxTargets.filter((c) => c.checked).forEach((c) => form.appendChild(this.#hidden(param, c.value)))
    document.body.appendChild(form)
    form.submit()
  }

  #hidden(name, value) {
    const i = document.createElement("input")
    i.type = "hidden"; i.name = name; i.value = value
    return i
  }

  #sync() {
    const total = this.checkboxTargets.length
    const selected = this.checkboxTargets.filter((c) => c.checked).length

    if (this.hasCountTarget) this.countTarget.textContent = String(selected)
    if (this.hasLabelTarget) {
      const { singular, plural } = this.labelTarget.dataset
      this.labelTarget.textContent = selected > 1 ? plural : singular
    }
    if (this.hasBarTarget) this.barTarget.toggleAttribute("data-visible", selected > 0)
    if (this.hasAllTarget) {
      this.allTarget.checked = selected > 0 && selected === total
      this.allTarget.indeterminate = selected > 0 && selected < total
    }
  }
}
