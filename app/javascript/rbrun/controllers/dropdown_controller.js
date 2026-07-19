// Primitives::Dropdown sidecar — a controller-owned floating menu panel
// anchored with Floating UI. The controller owns visibility, outside-press
// dismissal, Escape handling, focus return, and focusing the first menu item
// on open. Floating UI fills the positioning gap (CSS anchor positioning is
// not yet broadly supported), flipping/shifting to stay on screen.
//
// Markup contract (rendered by Primitives::Dropdown):
//   <div data-controller="dropdown"
//        data-dropdown-placement-value="top-start"
//        data-dropdown-offset-value="6">
//     <div data-dropdown-target="trigger" data-action="click->dropdown#toggle">…</div>
//     <div data-dropdown-target="content" hidden tabindex="-1">
//       <div role="menu">… role="menuitem" links …</div>
//     </div>
//   </div>
import { Controller } from "@hotwired/stimulus"
import { computePosition, autoUpdate, offset, flip, shift } from "@floating-ui/dom"

export default class extends Controller {
  static targets = ["trigger", "content"]
  static values = {
    placement: { type: String, default: "bottom-start" },
    offset: { type: Number, default: 6 }
  }

  #cleanup = null
  #open = false
  #restoreFocusTo = null

  connect() {
    this.#hide()
  }

  disconnect() {
    this.close()
  }

  toggle(event) {
    if (event) {
      event.preventDefault()
      event.stopPropagation()
    }
    this.#open ? this.close() : this.open()
  }

  open() {
    if (this.#open) return

    this.#open = true
    this.#restoreFocusTo = this.#focusableTrigger() || document.activeElement
    this.#show()
    this.#cleanup = autoUpdate(this.triggerTarget, this.contentTarget, () => this.#position())
    this.#bindGlobalListeners()
    this.#position()
    requestAnimationFrame(() => this.#focusFirstItem())
  }

  close() {
    if (!this.#open) return

    this.#open = false
    this.#unbindGlobalListeners()
    this.#stopTracking()
    this.#hide()
    this.#restoreFocus()
  }

  #position() {
    computePosition(this.triggerTarget, this.contentTarget, {
      strategy: "fixed",
      placement: this.placementValue,
      middleware: [offset(this.offsetValue), flip(), shift({ padding: 8 })]
    }).then(({ x, y }) => {
      Object.assign(this.contentTarget.style, { top: `${y}px`, left: `${x}px` })
    })
  }

  #bindGlobalListeners() {
    document.addEventListener("pointerdown", this.#handlePointerDown, true)
    document.addEventListener("keydown", this.#handleKeyDown, true)
  }

  #unbindGlobalListeners() {
    document.removeEventListener("pointerdown", this.#handlePointerDown, true)
    document.removeEventListener("keydown", this.#handleKeyDown, true)
  }

  #handlePointerDown = (event) => {
    const target = event.target
    if (!(target instanceof Node)) return
    if (this.triggerTarget.contains(target) || this.contentTarget.contains(target)) return
    this.close()
  }

  #handleKeyDown = (event) => {
    if (event.key === "Escape") {
      event.stopPropagation()
      this.close()
    }
  }

  #show() {
    this.contentTarget.hidden = false
    this.contentTarget.setAttribute("aria-hidden", "false")
    this.triggerTarget.setAttribute("aria-expanded", "true")
  }

  #hide() {
    this.contentTarget.hidden = true
    this.contentTarget.setAttribute("aria-hidden", "true")
    this.triggerTarget.setAttribute("aria-expanded", "false")
  }

  #focusFirstItem() {
    if (!this.#open) return
    const item = this.contentTarget.querySelector('[role="menuitem"]')
    ;(item || this.contentTarget).focus()
  }

  #focusableTrigger() {
    return this.triggerTarget.querySelector("button, a, [tabindex]") || null
  }

  #restoreFocus() {
    if (this.#restoreFocusTo instanceof HTMLElement && document.contains(this.#restoreFocusTo)) {
      this.#restoreFocusTo.focus()
    }
    this.#restoreFocusTo = null
  }

  #stopTracking() {
    if (this.#cleanup) {
      this.#cleanup()
      this.#cleanup = null
    }
  }
}
