import { Controller } from "@hotwired/stimulus";

// Keeps a streaming conversation pinned to the bottom — and gets out of the way the moment you
// scroll up to read something. A programmatic scroll is flagged and its event ignored (only a human
// un-pins); a MutationObserver catches streamed lines and a ResizeObserver catches layout settle
// (an image decoding changes height without a mutation).
export default class extends Controller {
  static targets = ["viewport", "button"];
  static values = { threshold: { type: Number, default: 40 } };

  connect() {
    this.pinned = true;
    this.programmatic = false;

    this.observer = new MutationObserver(() => this.#follow());
    this.observer.observe(this.viewportTarget, { childList: true, subtree: true });

    this.resizeObserver = new ResizeObserver(() => this.#follow());
    this.resizeObserver.observe(this.viewportTarget);
    for (const child of this.viewportTarget.children) this.resizeObserver.observe(child);

    this.#toBottom("auto");
    this.#syncButton();
  }

  disconnect() {
    this.observer.disconnect();
    this.resizeObserver.disconnect();
  }

  scrolled() {
    if (this.programmatic) return;
    this.pinned = this.#atBottom();
    this.#syncButton();
  }

  resume() {
    this.pinned = true;
    this.#toBottom("smooth");
    this.#syncButton();
  }

  #follow() {
    if (this.pinned) this.#toBottom("auto");
    this.#syncButton();
  }

  #toBottom(behavior) {
    this.programmatic = true;
    this.viewportTarget.scrollTo({ top: this.viewportTarget.scrollHeight, behavior });
    requestAnimationFrame(() => requestAnimationFrame(() => { this.programmatic = false; }));
  }

  #atBottom() {
    const el = this.viewportTarget;
    return el.scrollHeight - el.scrollTop - el.clientHeight <= this.thresholdValue;
  }

  #syncButton() {
    if (!this.hasButtonTarget) return;
    this.buttonTarget.classList.toggle("hidden", this.pinned);
    this.buttonTarget.classList.toggle("inline-flex", !this.pinned);
  }
}
