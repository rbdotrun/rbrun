import { Controller } from "@hotwired/stimulus"
import { Editor } from "@tiptap/core"
import StarterKit from "@tiptap/starter-kit"
import { Placeholder } from "@tiptap/extensions"

// Vanilla TipTap editor mounted by Stimulus (no React). Mirrors editor.getHTML() into a hidden input
// so the rich value posts as a normal Rails param. Faithfully ported from ../insitix.
export default class extends Controller {
  static targets = ["editor", "input"]
  static values = { content: String, placeholder: String }

  connect() {
    this.editor = new Editor({
      element: this.editorTarget,
      extensions: [
        StarterKit.configure({
          link: {
            openOnClick: false,
            autolink: true,
            HTMLAttributes: {
              class: "text-default-600 underline cursor-pointer",
              rel: "noopener noreferrer",
              target: "_blank"
            }
          }
        }),
        Placeholder.configure({ placeholder: this.placeholderValue })
      ],
      content: this.contentValue,
      onUpdate: ({ editor }) => { this.inputTarget.value = editor.getHTML() },
      onSelectionUpdate: () => this.refreshToolbar(),
      onTransaction: () => this.refreshToolbar()
    })
    this.refreshToolbar()
  }

  disconnect() {
    this.editor?.destroy()
  }

  // A format button: data-command (a TipTap chain method) + optional data-level.
  command(event) {
    const { command, level } = event.currentTarget.dataset
    const chain = this.editor.chain().focus()
    ;(level ? chain[command]({ level: Number(level) }) : chain[command]()).run()
  }

  // The link button: toggle off if on a link, else prompt for a URL.
  link() {
    const previous = this.editor.getAttributes("link").href
    if (previous) {
      this.editor.chain().focus().unsetLink().run()
      return
    }
    const url = window.prompt("Link URL:")
    if (url === null) return
    if (url === "") {
      this.editor.chain().focus().extendMarkRange("link").unsetLink().run()
      return
    }
    this.editor.chain().focus().extendMarkRange("link").setLink({ href: url }).run()
  }

  // Reflect active marks/nodes on the toolbar by toggling the active classes.
  refreshToolbar() {
    this.element.querySelectorAll("[data-rta-type]").forEach((btn) => {
      const { rtaType, level } = btn.dataset
      const active = this.editor.isActive(rtaType, level ? { level: Number(level) } : undefined)
      btn.classList.toggle("!text-default-600", active)
      btn.classList.toggle("bg-white", active)
    })
  }
}
