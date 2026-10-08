import { Controller } from "@hotwired/stimulus"

const LINKS = ".cnav a, .cfoot a"

export default class extends Controller {
  connect() {
    this.pop = document.createElement("div")
    this.pop.className = "hint"
    this.pop.setAttribute("role", "tooltip")
    document.body.appendChild(this.pop)

    this.onOver = (event) => this.show(event.target)
    this.onOut = (event) => {
      if (!event.relatedTarget?.closest?.(LINKS)) this.hide()
    }
    this.element.addEventListener("mouseover", this.onOver)
    this.element.addEventListener("mouseout", this.onOut)
    this.element.addEventListener("focusin", this.onOver)
    this.element.addEventListener("focusout", this.onOut)
  }

  disconnect() {
    this.element.removeEventListener("mouseover", this.onOver)
    this.element.removeEventListener("mouseout", this.onOut)
    this.element.removeEventListener("focusin", this.onOver)
    this.element.removeEventListener("focusout", this.onOut)
    this.pop.remove()
  }

  show(target) {
    const link = target.closest?.(LINKS)
    if (!link || !this.element.contains(link)) return this.hide()

    const label = [...link.children].find((el) => el.tagName === "SPAN" &&
      !el.classList.contains("community-nav-tally"))
    if (!label || !this.collapsed) return this.hide()

    const box = link.getBoundingClientRect()
    this.pop.textContent = label.textContent.trim()
    this.pop.style.left = `${Math.round(box.right + 8)}px`
    this.pop.style.top = `${Math.round(box.top + box.height / 2)}px`
    this.pop.classList.add("on")
  }

  get collapsed() {
    const icon = document.documentElement.classList.contains("sidebar-icon")
    if (matchMedia("(min-width: 1100px)").matches) return icon
    return matchMedia("(min-width: 900px)").matches && !icon
  }

  hide() {
    this.pop.classList.remove("on")
  }
}
