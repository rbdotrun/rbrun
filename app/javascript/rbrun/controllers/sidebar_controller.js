import { Controller } from "@hotwired/stimulus"

// Collapses the sidebar to an icon rail. The single source of truth is the
// `data-collapsed` attribute on the element — every visual change is Tailwind
// `group-data-[collapsed]/sidebar:*` variants keyed off it (width shrinks, text
// fades in place, icons never move). The state persists in a cookie so the
// server renders the collapsed markup directly (no flash, no width animation
// on page load).
export default class extends Controller {
  // The cookie the collapsed state persists in. Defaults to the app's, but each console names its
  // own (data-sidebar-cookie-value) so the app and the system console DON'T share one collapse
  // state — the toggler is shared, the state is not.
  static values = { cookie: { type: String, default: "sidebar_collapsed" } }

  // Enable width animation only AFTER first paint. On a Turbo navigation the rail is
  // rendered already-collapsed by the server; without this it would animate open→closed
  // from Turbo's cached preview (the flash). Two frames guarantees layout has settled.
  connect() {
    requestAnimationFrame(() =>
      requestAnimationFrame(() => this.element.setAttribute("data-ready", "")),
    )
  }

  toggle() {
    const collapsed = this.element.toggleAttribute("data-collapsed")

    document.cookie = collapsed
      ? `${this.cookieValue}=1; path=/; max-age=31536000`
      : `${this.cookieValue}=; path=/; max-age=0`
  }
}
