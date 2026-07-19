// Primitives::Menu sidecar — WAI-ARIA roving-tabindex keyboard navigation.
// Ported from the rbrun_ui Menu controller. Items declare themselves with
// `data-menu-target="item"`; one item holds tabindex=0 at a time and Arrow /
// Home / End move the active index. Enter/Space activate the focused item by
// clicking it (works for both <a> links and <button> form items).
//
// Focus resets to the first item every time the menu becomes visible in the
// viewport (IntersectionObserver) — so a menu inside a dropdown always starts
// at the top when the dropdown opens.
//
// Markup contract (rendered by Primitives::Menu):
//   <div data-controller="menu" data-action="keydown->menu#navigate" role="menu">
//     <a data-menu-target="item" role="menuitem" tabindex="-1">…</a>
//     ...
//   </div>
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["item"]
  static values = { index: Number }

  #observer

  initialize() {
    this.#observer = new IntersectionObserver(this.#onVisible.bind(this))
  }

  connect() {
    this.#observer.observe(this.element)
  }

  disconnect() {
    this.#observer.disconnect()
  }

  navigate(event) {
    switch (event.key) {
      case " ":
      case "Enter":
        this.#cancel(event)
        this.#activate(event.target)
        break
      case "ArrowUp":
        this.#cancel(event)
        this.#prev()
        break
      case "ArrowDown":
        this.#cancel(event)
        this.#next()
        break
      case "Home":
        this.#cancel(event)
        this.#first()
        break
      case "End":
        this.#cancel(event)
        this.#last()
        break
    }
  }

  #cancel(event) {
    event.stopPropagation()
    event.preventDefault()
  }

  #activate(item) {
    item.click()
  }

  #onVisible([entry]) {
    if (entry.isIntersecting) this.#first()
  }

  #prev() {
    if (this.indexValue > 0) {
      this.indexValue--
      this.#update()
    }
  }

  #next() {
    if (this.indexValue < this.#lastIndex) {
      this.indexValue++
      this.#update()
    }
  }

  #first() {
    if (this.#visibleItems.length === 0) {
      this.indexValue = -1
      this.#update()
      return
    }
    this.indexValue = 0
    this.#update()
  }

  #last() {
    if (this.#visibleItems.length === 0) {
      this.indexValue = -1
      this.#update()
      return
    }
    this.indexValue = this.#lastIndex
    this.#update()
  }

  #update() {
    const visibleItems = this.#visibleItems
    this.itemTargets.forEach(item => { item.tabIndex = -1 })
    visibleItems.forEach((item, index) => {
      item.tabIndex = index === this.indexValue ? 0 : -1
    })
    visibleItems[this.indexValue]?.focus()
  }

  get #visibleItems() {
    return this.itemTargets.filter(item => !item.hidden)
  }

  get #lastIndex() {
    return this.#visibleItems.length - 1
  }
}
