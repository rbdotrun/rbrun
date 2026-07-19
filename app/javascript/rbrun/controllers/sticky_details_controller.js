import { Controller } from "@hotwired/stimulus";

// A <details> whose open/closed state survives Turbo re-rendering. Segments are replaced in place
// while the agent streams; without this, every re-render would reset the disclosure to the server's
// default and fight the reader. Once you toggle it by hand, your choice is remembered by element id
// and restored on reconnect — the server default only applies until you touch it.
const STATE = new Map();

export default class extends Controller {
  connect() {
    const remembered = STATE.get(this.element.id);
    if (remembered !== undefined) this.element.open = remembered;
    this.onToggle = () => STATE.set(this.element.id, this.element.open);
    this.element.addEventListener("toggle", this.onToggle);
  }

  disconnect() {
    this.element.removeEventListener("toggle", this.onToggle);
  }
}
