import { Controller } from "@hotwired/stimulus"
import { scaleLinear } from "d3-scale"
import { line as lineOf, area as areaOf, curveLinear } from "d3-shape"

const PAD = { l: 42, r: 14, t: 12, b: 34 }
const TICKS = [0, 25, 50, 75, 100]

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const pct = (v, d = 1) => `${Number(v).toFixed(d)}%`

export default class extends Controller {
  static values = { points: Array, height: Number, gini: Number, marks: Array }

  connect() {
    this.at = null
    this.element.innerHTML = `<div class="chart tipped" tabindex="0"
      data-action="mousemove->lorenz#track mouseleave->lorenz#clear keydown->lorenz#key"
      ><div class="tip"></div><span class="chart-say" aria-live="polite"></span></div>`
    const chart = this.element.querySelector(".chart")
    this.watcher = new ResizeObserver(() => this.measure())
    this.watcher.observe(chart)
    this.wide = 0
    this.measure()
  }

  disconnect() {
    this.watcher?.disconnect()
  }

  get high() {
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 226
  }

  measure() {
    const chart = this.element.querySelector(".chart")
    const wide = chart ? chart.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(chart, wide)
  }

  draw(chart, wide) {
    const pts = this.pointsValue
    if (!pts.length) return

    const high = this.high
    const x = scaleLinear().domain([0, 100]).range([PAD.l, wide - PAD.r])
    const y = scaleLinear().domain([0, 100]).range([high - PAD.b, PAD.t])

    const seen = pts[0][0] === 0 ? pts : [[0, 0], ...pts]
    const path = lineOf().x((d) => x(d[0])).y((d) => y(d[1])).curve(curveLinear)
    const under = areaOf().x((d) => x(d[0])).y0(y(0)).y1((d) => y(d[1])).curve(curveLinear)

    const grid = TICKS.map((v) =>
      `<line class="grid" x1="${PAD.l}" y1="${y(v).toFixed(1)}" x2="${
        wide - PAD.r}" y2="${y(v).toFixed(1)}"/>` +
      `<text class="ax" x="${PAD.l - 7}" y="${(y(v) + 3.5).toFixed(1)}" text-anchor="end">${
        v}%</text>` +
      `<text class="ax" x="${x(v).toFixed(1)}" y="${y(0) + 15}" text-anchor="middle">${
        v}%</text>`).join("")

    const fair = `<line class="fair" x1="${x(0)}" y1="${y(0)}" x2="${x(100)}" y2="${y(100)}"/>`

    const marks = (this.hasMarksValue ? this.marksValue : []).map(([px, py]) =>
      `<circle class="pin" cx="${x(px).toFixed(1)}" cy="${y(py).toFixed(1)}" r="4"/>`).join("")

    chart.querySelector("svg")?.remove()
    chart.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary())}">${grid}${fair}` +
      `<path class="wash-fill" d="${under(seen)}"/>` +
      `<path class="curve" d="${path(seen)}" fill="none"/>${marks}` +
      `<line class="base" x1="${PAD.l}" y1="${y(0)}" x2="${wide - PAD.r}" y2="${y(0)}"/>` +
      `<line class="cur" x1="0" y1="${PAD.t}" x2="0" y2="${y(0)}" opacity="0"/>` +
      `<circle class="dot" r="4.5" opacity="0"/></svg>`)

    this.geom = { x, y, wide, high, pts: seen }
    if (this.at != null) this.show(this.at)
  }

  summary() {
    const pts = this.pointsValue
    const half = pts.find((p) => p[0] === 50)
    const top = pts.find((p) => p[0] === 90)
    const bits = [`concentration curve, ${pts.length} points`]
    if (half) bits.push(`bottom half of posters hold ${pct(half[1])} of messages`)
    if (top) bits.push(`top tenth hold ${pct(100 - top[1])}`)
    if (this.hasGiniValue) bits.push(`Gini ${Number(this.giniValue).toFixed(3)}`)
    return bits.join(", ")
  }

  track(event) {
    const g = this.geom
    if (!g) return

    const box = this.element.querySelector(".chart").getBoundingClientRect()
    const mx = event.clientX - box.left
    if (mx < PAD.l || mx > g.wide - PAD.r) return this.clear()

    const want = g.x.invert(mx)
    let best = 0
    g.pts.forEach((p, i) => {
      if (Math.abs(p[0] - want) < Math.abs(g.pts[best][0] - want)) best = i
    })
    this.show(best)
  }

  key(event) {
    const g = this.geom
    if (!g) return

    const last = g.pts.length - 1
    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key]
    let next = this.at

    if (step) next = this.at == null ? (step > 0 ? 0 : last) : Math.min(last, Math.max(0, this.at + step))
    else if (event.key === "Home") next = 0
    else if (event.key === "End") next = last
    else if (event.key === "Escape") return this.clear()
    else return

    event.preventDefault()
    this.show(next)
  }

  show(i) {
    const g = this.geom
    const chart = this.element.querySelector(".chart")
    const [px, py] = g.pts[i]
    this.at = i

    const tip = chart.querySelector(".tip")
    tip.innerHTML = `<div class="t">bottom ${px}% of posters</div>` +
      `<div class="row"><i class="ser-1"></i>of messages<b>${pct(py, 2)}</b></div>` +
      `<div class="row"><i class="ser-0"></i>if equal<b>${pct(px, 0)}</b></div>`
    tip.classList.add("on")

    const tipWide = tip.offsetWidth || 180
    let left = g.x(px) + 14
    if (left + tipWide > g.wide) left = g.x(px) - 14 - tipWide
    tip.style.left = `${Math.max(0, left)}px`
    tip.style.top = `${PAD.t}px`

    const cur = chart.querySelector(".cur")
    cur.setAttribute("x1", g.x(px))
    cur.setAttribute("x2", g.x(px))
    cur.setAttribute("opacity", "0.6")
    const dot = chart.querySelector(".dot")
    dot.setAttribute("cx", g.x(px))
    dot.setAttribute("cy", g.y(py))
    dot.setAttribute("opacity", "1")

    chart.querySelector(".chart-say").textContent =
      `bottom ${px} percent of posters hold ${pct(py, 2)} of messages`
  }

  clear() {
    const chart = this.element.querySelector(".chart")
    if (!chart) return

    this.at = null
    chart.querySelector(".tip")?.classList.remove("on")
    chart.querySelector(".cur")?.setAttribute("opacity", "0")
    chart.querySelector(".dot")?.setAttribute("opacity", "0")
    const say = chart.querySelector(".chart-say")
    if (say) say.textContent = ""
  }
}
