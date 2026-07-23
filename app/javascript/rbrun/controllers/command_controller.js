import { Controller } from "@hotwired/stimulus";

// The searchable command-menu behind the repo switcher — a Stimulus command palette (cmdk-style; rbrun
// has no React). It owns the query and the loading affordance: a debounced keystroke re-shows the
// skeleton, flips the input's spinner on, and points the results Turbo frame at the search endpoint;
// the server (repos scoped to the PAT) renders the matching rows back, and turbo:frame-render flips the
// spinner off and reveals the clear (X). The X clears the field and reloads the initial list (skeleton
// + spinner again). Keyboard nav + picking live elsewhere (the menu controller inside the frame).
export default class extends Controller {
  static targets = ["input", "frame", "spinner", "clear", "skeleton"];
  static values = { url: String, delay: { type: Number, default: 200 } };

  connect() {
    // Focus the input once the panel is revealed (the dialog opens the frame into view).
    this.observer = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) requestAnimationFrame(() => this.inputTarget?.focus());
    });
    if (this.hasInputTarget) this.observer.observe(this.inputTarget);
    if (this.hasFrameTarget) this.frameTarget.addEventListener("turbo:frame-render", this.loaded);
    this.#loading(false);
  }

  disconnect() {
    this.observer?.disconnect();
    clearTimeout(this.timer);
    if (this.hasFrameTarget) this.frameTarget.removeEventListener("turbo:frame-render", this.loaded);
  }

  search() {
    clearTimeout(this.timer);
    this.#loading(true);
    this.timer = setTimeout(() => this.#reload(), this.delayValue);
  }

  clear() {
    if (!this.hasInputTarget) return;
    this.inputTarget.value = "";
    this.inputTarget.focus();
    this.search(); // reload the initial list, with the skeleton + spinner in the process
  }

  // turbo:frame-render — the search request finished rendering its rows.
  loaded = () => this.#loading(false);

  #reload() {
    if (!this.hasFrameTarget) return;
    if (this.hasSkeletonTarget) this.frameTarget.replaceChildren(this.skeletonTarget.content.cloneNode(true));
    const url = new URL(this.urlValue, window.location.origin);
    url.searchParams.set("q", this.inputTarget.value.trim());
    this.frameTarget.src = url.pathname + url.search;
  }

  // Show the spinner while `on`; otherwise reveal the clear (X) only when the field has a value.
  #loading(on) {
    const hasValue = this.hasInputTarget && this.inputTarget.value.trim() !== "";
    if (this.hasSpinnerTarget) this.spinnerTarget.classList.toggle("hidden", !on);
    if (this.hasClearTarget) this.clearTarget.classList.toggle("hidden", on || !hasValue);
  }
}
