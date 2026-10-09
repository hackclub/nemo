import { Controller } from "@hotwired/stimulus"

const MONTHS = ["January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"]
const SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const DOW = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

const CHEVRON = (d) => `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`

function iso(date) {
  const m = String(date.getMonth() + 1).padStart(2, "0")
  const d = String(date.getDate()).padStart(2, "0")
  return `${date.getFullYear()}-${m}-${d}`
}

function parse(value) {
  if (!value) return null
  const [y, m, d] = String(value).split("-").map(Number)
  if (!y || !m || !d) return null
  return new Date(y, m - 1, d)
}

const same = (a, b) => a && b && a.getTime() === b.getTime()

export function rangeLabel(from, to) {
  if (!from || !to) return ""
  const left = `${SHORT[from.getMonth()]} ${from.getDate()}`
  const right = `${SHORT[to.getMonth()]} ${to.getDate()}, ${to.getFullYear()}`
  return from.getFullYear() === to.getFullYear()
    ? `${left} - ${right}`
    : `${left}, ${from.getFullYear()} - ${right}`
}

export default class extends Controller {
  static targets = ["start", "end", "trigger", "pop", "say"]
  static values = { min: String, max: String }

  connect() {
    this.min = parse(this.minValue)
    this.max = parse(this.maxValue)
    this.onDoc = (event) => {
      if (event.composedPath().includes(this.element)) return
      this.close()
    }
    this.onKey = (event) => {
      if (event.key !== "Escape") return
      this.close()
      this.triggerTarget.focus()
    }
    this.onMove = () => this.place()
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
    this.from = parse(this.startTarget.value)
    this.to = parse(this.endTarget.value)
    this.picking = false
    this.hover = null
    const anchor = this.to || this.max || new Date()
    this.view = new Date(anchor.getFullYear(), anchor.getMonth() - 1, 1)
    this.render()
    this.popTarget.showPopover()
    this.place()
    this.triggerTarget.setAttribute("aria-expanded", "true")
    document.addEventListener("click", this.onDoc)
    document.addEventListener("keydown", this.onKey)
    window.addEventListener("resize", this.onMove)
    document.addEventListener("scroll", this.onMove, true)
  }

  close() {
    if (!this.shown) return
    this.popTarget.hidePopover()
    this.triggerTarget.setAttribute("aria-expanded", "false")
    this.detach()
  }

  detach() {
    document.removeEventListener("click", this.onDoc)
    document.removeEventListener("keydown", this.onKey)
    window.removeEventListener("resize", this.onMove)
    document.removeEventListener("scroll", this.onMove, true)
  }

  place() {
    const box = this.triggerTarget.getBoundingClientRect()
    const pop = this.popTarget
    const wide = pop.offsetWidth
    const left = Math.max(12, Math.min(box.right - wide, window.innerWidth - wide - 12))
    pop.style.left = `${Math.round(left)}px`
    pop.style.top = `${Math.round(box.bottom + 6)}px`
  }

  shift(event) {
    const step = Number(event.currentTarget.dataset.step)
    this.view = new Date(this.view.getFullYear(), this.view.getMonth() + step, 1)
    this.render()
  }

  pick(event) {
    const day = parse(event.currentTarget.dataset.day)
    if (!day) return

    if (!this.picking) {
      this.from = day
      this.to = null
      this.picking = true
      this.render()
      return
    }

    this.picking = false
    if (day < this.from) [this.from, this.to] = [day, this.from]
    else this.to = day
    this.render()
    this.startTarget.value = iso(this.from)
    this.endTarget.value = iso(this.to)
    if (this.hasSayTarget) this.sayTarget.textContent = rangeLabel(this.from, this.to)
    this.close()
    this.startTarget.form?.requestSubmit()
  }

  preview(event) {
    if (!this.picking) return
    const day = parse(event.currentTarget.dataset.day)
    if (same(day, this.hover)) return
    this.hover = day
    this.paint()
  }

  get span() {
    const a = this.from
    const b = this.picking ? (this.hover || this.from) : this.to
    if (!a || !b) return [a, a]
    return a <= b ? [a, b] : [b, a]
  }

  render() {
    const months = [0, 1].map((n) => new Date(this.view.getFullYear(), this.view.getMonth() + n, 1))
    const prevOk = !this.min || new Date(months[0].getFullYear(), months[0].getMonth(), 0) >= this.min
    const nextOk = !this.max || new Date(months[1].getFullYear(), months[1].getMonth() + 1, 1) <= this.max

    this.popTarget.innerHTML = `<div class="rcal">
      <button type="button" class="btn btn-ghost btn-only btn-sm rcal-nav rcal-prev" data-step="-1"
        data-action="daterange#shift" aria-label="Previous month" ${prevOk ? "" : "disabled"}>${
        CHEVRON("m15 18-6-6 6-6")}</button>
      <button type="button" class="btn btn-ghost btn-only btn-sm rcal-nav rcal-next" data-step="1"
        data-action="daterange#shift" aria-label="Next month" ${nextOk ? "" : "disabled"}>${
        CHEVRON("m9 18 6-6-6-6")}</button>
      ${months.map((month) => this.month(month)).join("")}
    </div>`
    this.paint()
  }

  month(first) {
    const lead = first.getDay()
    const start = new Date(first.getFullYear(), first.getMonth(), 1 - lead)
    const days = Array.from({ length: 42 }, (_, i) =>
      new Date(start.getFullYear(), start.getMonth(), start.getDate() + i))
    const weeks = days[35].getMonth() === first.getMonth() ? 6 : (days[28].getMonth() === first.getMonth() ? 5 : 4)

    const cells = days.slice(0, weeks * 7).map((day) => {
      const out = day.getMonth() !== first.getMonth()
      const off = (this.min && day < this.min) || (this.max && day > this.max)
      return `<button type="button" class="rcal-day${out ? " rcal-out" : ""}" data-day="${iso(day)}"
        data-dow="${day.getDay()}" ${off ? "disabled" : ""}
        data-action="click->daterange#pick mouseenter->daterange#preview">${day.getDate()}</button>`
    }).join("")

    return `<div class="rcal-month">
      <div class="rcal-caption">${MONTHS[first.getMonth()]} ${first.getFullYear()}</div>
      <div class="rcal-grid">${DOW.map((d) => `<span class="rcal-dow">${d}</span>`).join("")}${cells}</div>
    </div>`
  }

  paint() {
    const [a, b] = this.span
    this.popTarget.querySelectorAll(".rcal-day").forEach((cell) => {
      const day = parse(cell.dataset.day)
      const out = cell.classList.contains("rcal-out")
      const inside = !out && a && b && day >= a && day <= b
      const edgeA = !out && same(day, a)
      const edgeB = !out && same(day, b)
      const dow = Number(cell.dataset.dow)
      const first = day.getDate() === 1
      const last = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1).getDate() === 1
      cell.classList.toggle("rcal-in", Boolean(inside))
      cell.classList.toggle("rcal-pick", Boolean(edgeA || edgeB))
      cell.classList.toggle("rcal-l", Boolean(inside && (edgeA || dow === 0 || first)))
      cell.classList.toggle("rcal-r", Boolean(inside && (edgeB || dow === 6 || last)))
      cell.setAttribute("aria-pressed", edgeA || edgeB ? "true" : "false")
    })
  }
}
