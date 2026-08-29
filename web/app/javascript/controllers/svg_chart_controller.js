import { Controller } from "@hotwired/stimulus"

const F = (n) => (n == null ? "n/a" : Number(n).toLocaleString("en-US"))

function nice(max) {
  if (!(max > 0)) return { step: 1, top: 1 }
  const raw = max / 4
  const mag = Math.pow(10, Math.floor(Math.log10(raw)))
  const step = [1, 2, 2.5, 5, 10].map((k) => k * mag).find((s) => s >= raw) || mag * 10
  return { step, top: Math.ceil(max / step) * step }
}

const axl = (v) => (Math.abs(v) >= 1000 ? `${+(v / 1000).toFixed(v % 1000 ? 1 : 0)}k` : String(v))

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

function seriesInk() {
  const css = getComputedStyle(document.documentElement)
  return [1, 2, 3, 4, 5, 0].map((n) => css.getPropertyValue(`--series-${n}`).trim())
}

export default class extends Controller {
  static values = { kind: String, data: Object, height: Number, pct: Boolean, switchable: Boolean }

  connect() {
    this.shown = this.kindValue
    this.render()
    this.observer = new MutationObserver(() => this.render())
    this.observer.observe(document.documentElement, { attributeFilter: ["data-theme"] })
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.onScheme = () => this.render()
    this.media.addEventListener("change", this.onScheme)
  }

  disconnect() {
    this.observer?.disconnect()
    this.media?.removeEventListener("change", this.onScheme)
  }

  get rows() {
    const { labels = [], datasets = [] } = this.dataValue
    return labels.map((label, i) => {
      const row = { label: Array.isArray(label) ? label[0] : label }
      datasets.forEach((set, s) => { row[`s${s}`] = set.data[i] })
      return row
    })
  }

  get series() {
    const ink = seriesInk()
    return (this.dataValue.datasets || []).map((set, i) => ({
      k: `s${i}`, n: set.label, c: set.color || ink[i % ink.length]
    }))
  }

  get height() {
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 214
  }

  render() {
    const rows = this.rows
    const series = this.series
    if (!rows.length || !series.length) return

    this.element.innerHTML =
      this.head(series) +
      `<div class="chart">${this.shown === "line"
        ? this.line(rows, series)
        : this.bars(rows, series)}<div class="tip"></div></div>`
    this.wire(rows, series)
  }

  head(series) {
    const legend = series.length > 1
      ? `<div class="chart-legend">${series
          .map((s) => `<span><i style="background:${esc(s.c)}"></i>${esc(s.n)}</span>`)
          .join("")}</div>`
      : ""
    if (!this.switchableValue) return legend

    const pick = (kind, label) =>
      `<button type="button" data-kind="${kind}" aria-current="${this.shown === kind}">${label}</button>`

    return `<div class="chart-head">${legend}<span class="segmented chart-pick">${
      pick("bars", "Bar")}${pick("line", "Line")}</span></div>`
  }

  pick(event) {
    const button = event.target.closest("[data-kind]")
    if (!button) return

    this.shown = button.dataset.kind
    this.render()
  }

  svg(h, inner) {
    return `<svg viewBox="0 0 980 ${h}" preserveAspectRatio="none" style="height:${h}px"><clipPath id="${this.clipId}"><rect x="0" y="0" width="980" height="${h}"/></clipPath><g clip-path="url(#${this.clipId})">${inner}</g></svg>`
  }

  get clipId() {
    this.clip ||= `chartclip-${Math.random().toString(36).slice(2, 9)}`
    return this.clip
  }

  line(rows, series) {
    const w = 980, h = this.height
    const all = rows.flatMap((r) => series.map((s) => r[s.k])).filter((v) => v != null)
    const lo = Math.min(...all), hi = Math.max(...all)
    const pad = (hi - lo) * 0.18 || 1
    const min = this.pctValue ? 0 : Math.max(0, lo - pad)
    const max = this.pctValue ? 100 : hi + pad
    const padL = 50, padB = 26
    const x = (i) => padL + (i * (w - padL - 8)) / Math.max(1, rows.length - 1)
    const y = (v) => 12 + (1 - (v - min) / (max - min || 1)) * (h - 12 - padB)
    this.geom = { x, y, w }

    const grid = [max, (max + min) / 2, min]
      .map((v) => `<line class="grid" x1="${padL}" y1="${y(v).toFixed(1)}" x2="${w}" y2="${y(v).toFixed(1)}"/>
        <text class="ax" x="${padL - 8}" y="${(y(v) + 3.5).toFixed(1)}" text-anchor="end">${
          this.pctValue ? `${Math.round(v)}%` : axl(Math.round(v))}</text>`)
      .join("")

    const paths = series.map((s) => {
      const vv = rows.map((r) => r[s.k])
      const pts = vv.map((v, i) => (v == null ? null : `${x(i).toFixed(1)},${y(v).toFixed(1)}`))
        .filter(Boolean).join(" ")
      const area = series.length === 1
        ? `<path d="M ${x(0)},${y(vv[0] ?? min)} ${vv.map((v, i) =>
            `L ${x(i).toFixed(1)},${y(v ?? min).toFixed(1)}`).join(" ")} L ${x(vv.length - 1)},${h - padB} L ${padL},${h - padB} Z"
            fill="${esc(s.c)}" opacity="0.07"/>`
        : ""
      return `${area}<polyline fill="none" stroke="${esc(s.c)}" stroke-width="2"
        stroke-linejoin="round" stroke-linecap="round" points="${pts}"/>
        <circle class="curdot" data-s="${s.k}" r="4.5" fill="${esc(s.c)}"
          stroke="var(--card)" stroke-width="2" opacity="0"/>`
    }).join("")

    const hits = rows.map((_, i) =>
      `<rect class="hit" data-i="${i}" x="${(x(i) - (w - padL) / rows.length / 2).toFixed(1)}" y="0"
        width="${((w - padL) / rows.length).toFixed(1)}" height="${h - padB}"/>`).join("")

    return this.svg(h, `${grid}${paths}
      <line class="cur" x1="0" y1="8" x2="0" y2="${h - padB}" stroke="var(--ink-3)"
        stroke-width="1" stroke-dasharray="3 3" opacity="0"/>
      <line class="base" x1="${padL}" y1="${h - padB}" x2="${w}" y2="${h - padB}"/>
      <text class="ax" x="${padL}" y="${h - 8}">${esc(rows[0].label)}</text>
      <text class="ax" x="${w}" y="${h - 8}" text-anchor="end">${esc(rows[rows.length - 1].label)}</text>
      ${hits}`)
  }

  bars(rows, series) {
    const w = 980, h = this.height
    const peak = Math.max(...rows.flatMap((r) => series.map((s) => r[s.k] || 0)))
    const { step, top: max } = nice(peak)
    const padL = 50, padB = 34, tp = 14
    const band = (w - padL) / rows.length
    const gap = Math.max(3, band * 0.22)
    const cap = Math.min(band * 0.62, 96)
    const bw = Math.max(4, Math.min(cap, (band - gap - (series.length - 1) * 2) / series.length))
    const y = (v) => tp + (1 - v / (max || 1)) * (h - tp - padB)

    const ticks = []
    for (let v = step; v <= max + 0.001; v += step) ticks.push(v)
    const grid = ticks.map((v) =>
      `<line class="grid" x1="${padL}" y1="${y(v).toFixed(1)}" x2="${w}" y2="${y(v).toFixed(1)}"/>
       <text class="ax" x="${padL - 8}" y="${(y(v) + 3.5).toFixed(1)}" text-anchor="end">${axl(v)}</text>`).join("")

    const every = Math.ceil(rows.length / 14)
    const bars = rows.map((r, i) => {
      const cx = padL + band * i + band / 2
      const total = series.length * bw + (series.length - 1) * 2
      const marks = series.map((s, j) => {
        const bx = cx - total / 2 + j * (bw + 2)
        const v = r[s.k] || 0
        return `<rect x="${bx.toFixed(1)}" y="${y(v).toFixed(1)}" width="${bw.toFixed(1)}"
          height="${Math.max(0, h - padB - y(v)).toFixed(1)}" rx="2" fill="${esc(s.c)}"/>`
      }).join("")
      return `<g class="mark" data-i="${i}">${marks}
        ${i % every === 0 || i === rows.length - 1
          ? `<text class="ax" x="${cx.toFixed(1)}" y="${h - padB + 17}" text-anchor="middle">${esc(r.label)}</text>`
          : ""}
        <rect class="hit" data-i="${i}" x="${(padL + band * i).toFixed(1)}" y="0"
          width="${band.toFixed(1)}" height="${h - padB}"/>
      </g>`
    }).join("")

    return this.svg(h, `${grid}<line class="base" x1="${padL}" y1="${h - padB}" x2="${w}" y2="${h - padB}"/>${bars}`)
  }

  wire(rows, series) {
    const chart = this.element.querySelector(".chart")
    const tip = chart.querySelector(".tip")
    const cur = chart.querySelector(".cur")
    const dots = [...chart.querySelectorAll(".curdot")]
    const marks = [...chart.querySelectorAll(".mark")]
    const pct = this.pctValue

    chart.querySelectorAll(".hit").forEach((hit) => {
      hit.addEventListener("mouseenter", () => {
        const i = +hit.dataset.i, r = rows[i]
        const box = chart.getBoundingClientRect()

        if (cur) {
          const x = this.geom.x(i)
          cur.setAttribute("x1", x); cur.setAttribute("x2", x); cur.setAttribute("opacity", "0.6")
          dots.forEach((d, j) => {
            const v = r[series[j].k]
            if (v == null) { d.setAttribute("opacity", "0"); return }
            d.setAttribute("cx", x); d.setAttribute("cy", this.geom.y(v)); d.setAttribute("opacity", "1")
          })
        }
        marks.forEach((m, j) => m.classList.toggle("fade", j !== i))

        tip.innerHTML = `<div class="t">${esc(r.label)}</div>` + series.map((s) =>
          r[s.k] == null ? "" :
            `<div class="row"><i style="background:${esc(s.c)}"></i>${esc(s.n)}<b>${
              pct ? `${Number(r[s.k]).toFixed(1)}%` : F(r[s.k])}</b></div>`).join("")

        const px = cur
          ? (this.geom.x(i) / this.geom.w) * box.width
          : (i + 0.5) * (box.width / rows.length)
        tip.style.left = `${Math.min(Math.max(px - 84, 0), Math.max(0, box.width - 190))}px`
        tip.style.top = cur ? "0px" : "6px"
        tip.classList.add("on")
      })
    })

    this.element.querySelector(".chart-pick")
      ?.addEventListener("click", (e) => this.pick(e))

    chart.addEventListener("mouseleave", () => {
      cur?.setAttribute("opacity", "0")
      dots.forEach((d) => d.setAttribute("opacity", "0"))
      marks.forEach((m) => m.classList.remove("fade"))
      tip.classList.remove("on")
    })
  }
}
