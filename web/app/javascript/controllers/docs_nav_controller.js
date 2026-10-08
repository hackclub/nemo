import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["body", "toc"]

  connect() {
    if (!this.hasTocTarget || !this.hasBodyTarget) return

    const sections = [...this.bodyTarget.querySelectorAll(".doc-sec[id]")]
    this.watch = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) this.mark(entry.target.id)
      })
    }, { rootMargin: "0px 0px -70% 0px" })
    sections.forEach((section) => this.watch.observe(section))
    if (sections[0]) this.mark(location.hash.slice(1) || sections[0].id)
  }

  disconnect() {
    this.watch?.disconnect()
  }

  mark(id) {
    this.tocTarget.querySelectorAll("a").forEach((link) => {
      link.toggleAttribute("aria-current", link.dataset.id === id)
    })
  }

  go(event) {
    const link = event.target.closest("a[href^='#']")
    if (!link || !this.element.contains(link)) return

    const id = link.getAttribute("href").slice(1)
    const section = document.getElementById(id)
    if (!section) return

    event.preventDefault()
    section.scrollIntoView({ behavior: this.easing, block: "start" })
    history.replaceState(history.state, "", `#${id}`)
    this.mark(id)
  }

  get easing() {
    return matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
  }
}
