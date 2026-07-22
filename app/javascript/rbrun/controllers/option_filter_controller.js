import { Controller } from "@hotwired/stimulus"

// Client-side typeahead over an already-rendered option list (nothing to fetch) — typing hides
// non-matching labels, accent-insensitive. When options are grouped, a parent group with no visible
// option hides too. Faithfully ported from ../insitix.
export default class extends Controller {
  static targets = ["input", "option", "group"]

  filter() {
    const needle = this.normalize(this.inputTarget.value)
    this.optionTargets.forEach((el) => {
      el.hidden = needle !== "" && !this.normalize(el.textContent).includes(needle)
    })
    this.groupTargets.forEach((group) => {
      const options = group.querySelectorAll("[data-option-filter-target='option']")
      group.hidden = Array.from(options).every((o) => o.hidden)
    })
  }

  normalize(value) {
    return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim()
  }
}
