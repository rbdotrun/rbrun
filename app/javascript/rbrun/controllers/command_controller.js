import { Controller } from "@hotwired/stimulus";

// The searchable command-menu behind the repo switcher — a Stimulus command palette (cmdk-style;
// rbrun has no React). It owns only the query: a debounced keystroke points
// the results Turbo frame at the search endpoint, and the server (GitHub search via the PAT) renders
// the matching repo rows back into the frame. Keyboard nav + picking are handled elsewhere (the menu
// controller inside the frame; each row is a turbo POST to switch). On open, focus the input.
export default class extends Controller {
  static targets = ["input", "frame"];
  static values = { url: String, delay: { type: Number, default: 200 } };

  connect() {
    // The dropdown reveals the panel by unhiding it; focus the input on the next frame.
    this.observer = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) requestAnimationFrame(() => this.inputTarget?.focus());
    });
    if (this.hasInputTarget) this.observer.observe(this.inputTarget);
  }

  disconnect() {
    this.observer?.disconnect();
    clearTimeout(this.timer);
  }

  search() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.#reload(), this.delayValue);
  }

  #reload() {
    if (!this.hasFrameTarget) return;
    const url = new URL(this.urlValue, window.location.origin);
    url.searchParams.set("q", this.inputTarget.value.trim());
    this.frameTarget.src = url.pathname + url.search;
  }
}
