import { Controller } from "@hotwired/stimulus";

// The message composer: a one-line textarea that grows with its content, sends on Enter
// (Shift+Enter for a newline), keeps the send button disabled while empty, and resets itself
// once Turbo confirms the submission landed.
export default class extends Controller {
  static targets = ["input", "send"];

  connect() {
    this.#resize();
    this.#syncSend();
    this.submitEnd = () => this.#reset();
    this.element.addEventListener("turbo:submit-end", this.submitEnd);
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.submitEnd);
  }

  input() {
    this.#resize();
    this.#syncSend();
  }

  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      if (this.#hasContent()) this.element.requestSubmit();
    }
  }

  #reset() {
    if (!this.hasInputTarget) return;
    this.inputTarget.value = "";
    this.#resize();
    this.#syncSend();
    this.inputTarget.focus();
  }

  #resize() {
    if (!this.hasInputTarget) return;
    const el = this.inputTarget;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }

  #hasContent() {
    return this.hasInputTarget && this.inputTarget.value.trim().length > 0;
  }

  #syncSend() {
    if (this.hasSendTarget) this.sendTarget.disabled = !this.#hasContent();
  }
}
