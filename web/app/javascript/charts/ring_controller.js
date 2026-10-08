import { Controller } from "@hotwired/stimulus"

const STROKE = 10
const GAP = 5
const INK = [1, 2, 3, 4, 5, 0]

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const F = (n) => Number(n || 0).toLocaleString("en-US")

const pct = (part, whole) => {
  if (!(whole > 0)) return "n/a"
  const v = (part / whole) * 100
  return v >= 10 || v === 0 ? `${Math.round(v)}%` : `${v.toFixed(1)}%`
}

function arc(cx, cy, r, share) {
  const sweep = Math.min(share, 0.9999) * 2 * Math.PI
  const a0 = -Math.PI / 2
  const a1 = a0 + sweep
  const [x0, y0] = [cx + r * Math.cos(a0), cy + r * Math.sin(a0)]
  const [x1, y1] = [cx + r * Math.cos(a1), cy + r * Math.sin(a1)]
  return `M ${x0.toFixed(2)} ${y0.toFixed(2)} A ${r} ${r} 0 ${sweep > Math.PI ? 1 : 0} 1 ${
    x1.toFixed(2)} ${y1.toFixed(2)}`
}

export default class extends Controller {
  static values = { items: Array, total: Number, label: String, size: Number }

  connect() {
    this.element.classList.add("ring")
    this.draw()
  }

  get items() {
    return (this.itemsValue || [])
      .map((item) => ({ ...item, value: Number(item.value) || 0 }))
      .sort((a, b) => b.value - a.value)
      .map((item, i) => ({ ...item, ink: item.ink ?? INK[i % INK.length] }))
  }

  get total() {
    if (this.hasTotalValue && this.totalValue > 0) return this.totalValue
    return this.items.reduce((sum, item) => sum + item.value, 0)
  }

  draw() {
    const items = this.items
    if (!items.length) return

    const size = this.hasSizeValue && this.sizeValue > 0 ? this.sizeValue : 200
    const c = size / 2
    const total = this.total
    const rings = items.map((item, i) => {
      const r = c - STROKE / 2 - i * (STROKE + GAP)
      if (r < STROKE * 2) return ""
      return `<g class="ring-band" data-i="${i}" style="--i:${i}">` +
        `<circle class="ring-track" cx="${c}" cy="${c}" r="${r}" stroke-width="${STROKE}"/>` +
        (item.value > 0
          ? `<path class="ring-arc ser-${item.ink}" d="${arc(c, c, r, item.value / total)}"
              stroke-width="${STROKE}" pathLength="1"/>`
          : "") + "</g>"
    }).join("")

    const legend = items.map((item, i) =>
      `<li class="ring-row" data-i="${i}" data-action="mouseenter->ring#lit mouseleave->ring#unlit">
        <span class="ring-name"><i class="ser-${item.ink}"></i>${esc(item.label)}</span>
        <span class="ring-num">${F(item.value)}<span>${pct(item.value, total)}</span></span>
        <span class="ring-bar"><b class="ser-${item.ink}" style="width:${
          Math.min(100, (item.value / total) * 100).toFixed(1)}%"></b></span>
      </li>`).join("")

    this.element.innerHTML = `<div class="ring-art">
        <svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" role="img"
          aria-label="${esc(`${this.labelValue || "total"} ${F(total)}: ${items.map((item) =>
            `${item.label} ${F(item.value)}`).join(", ")}`)}">${rings}</svg>
        <div class="ring-mid"><b>${F(total)}</b><span>${esc(this.labelValue || "")}</span></div>
      </div>
      <ul class="ring-legend">${legend}</ul>`
    this.element.classList.add("is-entering")
    setTimeout(() => this.element.classList.remove("is-entering"), 1600)
  }

  lit(event) {
    const i = event.currentTarget.dataset.i
    this.element.classList.add("lit")
    this.element.querySelectorAll("[data-i]").forEach((el) =>
      el.classList.toggle("on", el.dataset.i === i))
  }

  unlit() {
    this.element.classList.remove("lit")
    this.element.querySelectorAll(".on").forEach((el) => el.classList.remove("on"))
  }
}
