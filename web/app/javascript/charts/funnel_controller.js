import { Controller } from "@hotwired/stimulus"

const GAP = 4
const LAYERS = 3
const TOP = 30
const FOOT = 30
const PILL_H = 22

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const F = (n) => Number(n || 0).toLocaleString("en-US")

const compact = (n) => {
  const v = Number(n || 0)
  if (Math.abs(v) >= 1e6) return `${+(v / 1e6).toFixed(1)}m`
  if (Math.abs(v) >= 1e4) return `${Math.round(v / 1e3)}k`
  if (Math.abs(v) >= 1e3) return `${+(v / 1e3).toFixed(1)}k`
  return F(v)
}

const share = (part, whole) => {
  if (!(whole > 0)) return null
  const pct = (part / whole) * 100
  return pct >= 10 || pct === 0 ? `${Math.round(pct)}%` : `${pct.toFixed(1)}%`
}

const RULER = typeof document === "undefined"
  ? null
  : document.createElement("canvas").getContext("2d")

function wideAs(text) {
  if (!RULER) return String(text).length * 7
  RULER.font = '700 12px Geist, ui-sans-serif, system-ui, sans-serif'
  return RULER.measureText(String(text)).width
}

function band(norm0, norm1, x, w, my, h, scale) {
  const h0 = norm0 * h * 0.44 * scale
  const h1 = norm1 * h * 0.44 * scale
  const cx = w * 0.55
  return `M ${x} ${my - h0} C ${x + cx} ${my - h0}, ${x + w - cx} ${my - h1}, ${x + w} ${my - h1}` +
    ` L ${x + w} ${my + h1} C ${x + w - cx} ${my + h1}, ${x + cx} ${my + h0}, ${x} ${my + h0} Z`
}

export default class extends Controller {
  static values = { stages: Array, height: Number, ink: Number, label: String }

  connect() {
    this.at = null
    this.fresh = true
    this.element.innerHTML = `<div class="chart funnel tipped" tabindex="0"
      data-action="mousemove->funnel#track mouseleave->funnel#clear keydown->funnel#key"
      ><div class="tip"></div><span class="chart-caption" aria-live="polite"></span></div>`
    const box = this.element.querySelector(".chart")
    this.watcher = new ResizeObserver(() => this.measure())
    this.watcher.observe(box)
    this.wide = 0
    this.measure()
  }

  disconnect() {
    this.watcher?.disconnect()
    clearTimeout(this.entered)
  }

  get stages() {
    return (this.stagesValue || []).filter((s) => s && s.value != null)
  }

  get high() {
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 260
  }

  measure() {
    const box = this.element.querySelector(".chart")
    const wide = box ? box.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(box, wide)
  }

  draw(box, wide) {
    const stages = this.stages
    if (!stages.length) return

    const n = stages.length
    const high = this.high
    const h = high - TOP - FOOT
    const my = TOP + h / 2
    const segW = (wide - GAP * (n - 1)) / n
    const first = Number(stages[0].value) || 0
    const norms = stages.map((s) => (first > 0 ? Math.max(Number(s.value) || 0, 0) / first : 0))
    const ink = this.hasInkValue ? this.inkValue : 1

    const segs = stages.map((stage, i) => {
      const x = i * (segW + GAP)
      const n0 = Math.max(norms[i], 0.012)
      const n1 = Math.max(i < n - 1 ? norms[i + 1] : norms[i], 0.012)
      const rings = Array.from({ length: LAYERS }, (_, l) => {
        const scale = 1 - (l / LAYERS) * 0.35
        const opacity = 0.18 + (l / (LAYERS - 1)) * 0.65
        return `<path d="${band(n0, n1, x, segW, my, h, scale)}" fill="currentColor"
          fill-opacity="${opacity.toFixed(2)}"/>`
      }).join("")

      const pct = share(Number(stage.value) || 0, first) || "n/a"
      const pillW = wideAs(pct) + 24
      const cx = x + segW / 2
      return `<g class="funnel-seg ser-${ink}" data-i="${i}" style="--i:${i}">${rings}</g>` +
        `<g class="funnel-says" data-i="${i}" style="--i:${i}">` +
        `<text class="funnel-value" x="${cx.toFixed(1)}" y="${TOP - 10}" text-anchor="middle">${
          esc(compact(stage.value))}</text>` +
        `<g class="funnel-pill"><rect x="${(cx - pillW / 2).toFixed(1)}" y="${(my - PILL_H / 2).toFixed(1)}"
          width="${pillW.toFixed(1)}" height="${PILL_H}" rx="6"/><text x="${cx.toFixed(1)}"
          y="${(my + 4).toFixed(1)}" text-anchor="middle">${esc(pct)}</text></g>` +
        `<text class="ax funnel-stage" x="${cx.toFixed(1)}" y="${high - 10}" text-anchor="middle">${
          esc(stage.label)}</text></g>`
    }).join("")

    const seams = stages.slice(1).map((_, i) => {
      const at = (i + 1) * (segW + GAP) - GAP / 2
      return `<line class="funnel-seam" x1="${at.toFixed(1)}" y1="${TOP}" x2="${at.toFixed(1)}"
        y2="${(TOP + h).toFixed(1)}"/>`
    }).join("")

    box.querySelector("svg")?.remove()
    box.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary(stages))}">${seams}${segs}</svg>`)

    this.geom = { wide, high, segW, n, first, my }
    if (this.fresh) {
      this.fresh = false
      box.classList.add("is-entering")
      clearTimeout(this.entered)
      this.entered = setTimeout(() => box.classList.remove("is-entering"), 1600)
    }
    if (this.at != null) this.show(Math.min(this.at, n - 1))
  }

  summary(stages) {
    const first = Number(stages[0].value) || 0
    const what = this.hasLabelValue && this.labelValue ? this.labelValue : "funnel"
    return `${what}: ${stages.map((s) =>
      `${s.label} ${F(s.value)} (${share(Number(s.value) || 0, first) || "n/a"})`).join(", ")}`
  }

  track(event) {
    const g = this.geom
    if (!g) return

    const box = this.element.querySelector(".chart").getBoundingClientRect()
    const mx = event.clientX - box.left
    const i = Math.min(g.n - 1, Math.max(0, Math.floor(mx / (g.segW + GAP))))
    if (i !== this.at) this.show(i)
  }

  key(event) {
    const g = this.geom
    if (!g) return

    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key]
    let next = this.at
    if (step) next = this.at == null ? (step > 0 ? 0 : g.n - 1) : Math.min(g.n - 1, Math.max(0, this.at + step))
    else if (event.key === "Home") next = 0
    else if (event.key === "End") next = g.n - 1
    else if (event.key === "Escape") return this.clear()
    else return

    event.preventDefault()
    this.show(next)
  }

  show(i) {
    const g = this.geom
    const stages = this.stages
    const stage = stages[i]
    if (!g || !stage) return

    this.at = i
    const box = this.element.querySelector(".chart")
    const value = Number(stage.value) || 0
    const prev = i > 0 ? Number(stages[i - 1].value) || 0 : null
    const ink = this.hasInkValue ? this.inkValue : 1

    const tip = box.querySelector(".tip")
    tip.innerHTML = `<div class="t">${esc(stage.label)}</div>` +
      `<div class="row"><i class="ser-${ink}"></i>${esc(this.labelValue || "count")}<b>${F(value)}</b></div>` +
      (i > 0 ? `<div class="row"><i class="ser-none"></i>of ${esc(stages[0].label)}<b>${
        share(value, g.first) || "n/a"}</b></div>` : "") +
      (prev != null ? `<div class="row"><i class="ser-none"></i>of the step before<b>${
        share(value, prev) || "n/a"}</b></div>` : "") +
      (stage.note ? `<div class="row row-note"><i></i>${esc(stage.note)}</div>` : "")
    tip.classList.add("on")

    const tipWide = tip.offsetWidth || 180
    const left = i * (g.segW + GAP) + g.segW + 8
    tip.style.left = `${left + tipWide > g.wide ? Math.max(0, i * (g.segW + GAP) - tipWide - 8) : left}px`
    tip.style.top = `${TOP}px`

    box.classList.add("lit")
    box.querySelectorAll(".funnel-seg, .funnel-says").forEach((seg) =>
      seg.classList.toggle("on", +seg.dataset.i === i))
    box.querySelector(".chart-caption").textContent =
      `${stage.label}, ${F(value)}, ${share(value, g.first) || "n/a"} of ${stages[0].label}`
  }

  clear() {
    const box = this.element.querySelector(".chart")
    if (!box) return

    this.at = null
    box.querySelector(".tip")?.classList.remove("on")
    box.classList.remove("lit")
    box.querySelectorAll(".funnel-seg.on, .funnel-says.on").forEach((seg) => seg.classList.remove("on"))
    const say = box.querySelector(".chart-caption")
    if (say) say.textContent = ""
  }
}
