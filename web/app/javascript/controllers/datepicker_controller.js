import { Controller } from "@hotwired/stimulus"

const MONTHS = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"]
const DOW = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

function iso(date) {
  const m = String(date.getMonth() + 1).padStart(2, "0")
  const d = String(date.getDate()).padStart(2, "0")
  return `${date.getFullYear()}-${m}-${d}`
}

function parse(value) {
  if (!value) return null
  const [y, m, d] = value.split("-").map(Number)
  if (!y || !m || !d) return null
  return new Date(y, m - 1, d)
}

export default class extends Controller {
  static targets = ["input", "trigger", "pop"]
  static values = { min: String, max: String }

  connect() {
    this.min = parse(this.minValue)
    this.max = parse(this.maxValue)
    this.onDoc = (event) => {
      const path = typeof event.composedPath === "function" ? event.composedPath() : []
      if (path.includes(this.element)) return
      if (this.element.contains(event.target)) return
      this.close()
    }
    this.onKey = (event) => {
      if (event.key === "Escape") {
        this.close()
        this.triggerTarget.focus()
      }
    }
  }

  disconnect() {
    this.detach()
  }

  get shown() {
    return this.popTarget.matches(":popover-open")
  }

  toggle() {
    this.shown ? this.close() : this.open()
  }

  open() {
    this.view = this.selected() || this.max || new Date()
    this.render()
    this.popTarget.showPopover()
    this.place()
    this.triggerTarget.setAttribute("aria-expanded", "true")
    this.onMove = () => this.place()
    document.addEventListener("click", this.onDoc)
    document.addEventListener("keydown", this.onKey)
    window.addEventListener("resize", this.onMove)
    document.addEventListener("scroll", this.onMove, true)
  }

  close() {
    if (this.shown) this.popTarget.hidePopover()
    this.triggerTarget.setAttribute("aria-expanded", "false")
    this.detach()
  }

  place() {
    const pop = this.popTarget
    const btn = this.triggerTarget.getBoundingClientRect()
    pop.style.left = "0px"
    pop.style.top = "0px"
    const box = pop.getBoundingClientRect()
    const edge = 8
    const gap = 5

    let top = btn.bottom + gap
    if (top + box.height > window.innerHeight - edge) {
      const over = btn.top - gap - box.height
      top = over >= edge ? over : Math.max(edge, window.innerHeight - edge - box.height)
    }
    const left = Math.max(edge, Math.min(btn.left, window.innerWidth - edge - box.width))

    pop.style.left = `${Math.round(left)}px`
    pop.style.top = `${Math.round(top)}px`
  }

  detach() {
    document.removeEventListener("click", this.onDoc)
    document.removeEventListener("keydown", this.onKey)
    if (!this.onMove) return

    window.removeEventListener("resize", this.onMove)
    document.removeEventListener("scroll", this.onMove, true)
    this.onMove = null
  }

  selected() {
    return parse(this.inputTarget.value)
  }

  shift(event) {
    const step = Number(event.currentTarget.dataset.step)
    this.view = new Date(this.view.getFullYear(), this.view.getMonth() + step, 1)
    this.render()
  }

  pick(event) {
    const value = event.currentTarget.dataset.date
    this.inputTarget.value = value
    const date = parse(value)
    this.triggerTarget.textContent = `${MONTHS[date.getMonth()].slice(0, 3)} ${date.getDate()}, ${date.getFullYear()}`
    this.close()
    this.triggerTarget.focus()
  }

  outOfBounds(date) {
    if (this.min && date < this.min) return true
    if (this.max && date > this.max) return true
    return false
  }

  render() {
    const year = this.view.getFullYear()
    const month = this.view.getMonth()
    const first = new Date(year, month, 1)
    const days = new Date(year, month + 1, 0).getDate()
    const lead = (first.getDay() + 6) % 7
    const chosen = this.selected()
    const chosenIso = chosen ? iso(chosen) : null

    const prevEnd = new Date(year, month, 0)
    const nextStart = new Date(year, month + 1, 1)

    let cells = ""
    for (let i = 0; i < lead; i += 1) cells += `<span class="dp-blank"></span>`
    for (let day = 1; day <= days; day += 1) {
      const date = new Date(year, month, day)
      const value = iso(date)
      const disabled = this.outOfBounds(date) ? "disabled" : ""
      const selected = value === chosenIso ? ' aria-selected="true"' : ""
      cells += `<button type="button" class="dp-day" data-date="${value}" ${disabled}${selected} data-action="datepicker#pick">${day}</button>`
    }

    this.popTarget.innerHTML = `
      <div class="dp-head">
        <button type="button" class="dp-nav" data-step="-1" data-action="datepicker#shift"
          aria-label="previous month"${this.min && prevEnd < this.min ? " disabled" : ""}>&lsaquo;</button>
        <span class="dp-title">${MONTHS[month]} ${year}</span>
        <button type="button" class="dp-nav" data-step="1" data-action="datepicker#shift"
          aria-label="next month"${this.max && nextStart > this.max ? " disabled" : ""}>&rsaquo;</button>
      </div>
      <div class="dp-grid">
        ${DOW.map((d) => `<span class="dp-dow">${d}</span>`).join("")}
        ${cells}
      </div>
    `
  }
}
