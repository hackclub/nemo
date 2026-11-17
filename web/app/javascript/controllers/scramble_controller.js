import { Controller } from "@hotwired/stimulus"

const GLYPHS = "abcdefghijklmnopqrstuvwxyz0123456789$#%&*"
const FRAME_MS = 35
const FRAMES_PER_CHARACTER = 2

export default class extends Controller {
  connect() {
    this.text = this.element.textContent
  }

  disconnect() {
    this.finish()
  }

  reveal() {
    if (this.timer || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    let frame = 0
    this.timer = setInterval(() => {
      frame += 1
      const resolved = Math.floor(frame / FRAMES_PER_CHARACTER)
      if (resolved >= this.text.length) return this.finish()

      this.element.textContent = [...this.text].map((character, index) =>
        index < resolved || character.trim() === "" ? character : this.randomGlyph()
      ).join("")
    }, FRAME_MS)
  }

  finish() {
    if (!this.timer) return

    clearInterval(this.timer)
    this.timer = null
    this.element.textContent = this.text
  }

  randomGlyph() {
    return GLYPHS[Math.floor(Math.random() * GLYPHS.length)]
  }
}
