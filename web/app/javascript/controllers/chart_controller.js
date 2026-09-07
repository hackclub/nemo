import { Controller } from "@hotwired/stimulus"
import { scaleBand, scaleLinear } from "d3-scale"
import { line as lineOf, area as areaOf, curveMonotoneX, curveLinear } from "d3-shape"

let seq = 0

const INK = [1, 2, 3, 4, 5, 0]

const PAD = { l: 46, r: 8, t: 12, b: 28 }

const BAR_CAP = 72
const BAR_R = 3
const SEG_GAP = 2
const LABEL_ROOM = 64

const F = (n) => (n == null ? "n/a" : Number(n).toLocaleString("en-US"))

const axl = (v) =>
  Math.abs(v) >= 1000 ? `${+(v / 1000).toFixed(v % 1000 ? 1 : 0)}k` : `${Math.round(v)}`

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)

function topBar(x, y, w, h, r) {
  if (!(h > 0) || !(w > 0)) return ""

  const k = Math.min(r, w / 2, h)
  return `M${x},${y + h}V${y + k}a${k},${k} 0 0 1 ${k},${-k}h${w - 2 * k}a${k},${k} 0 0 1 ${k},${k}V${y + h}Z`
}

const ISO = /^\d{4}-\d{2}-\d{2}$/

function dayStep(iso, n) {
  const at = new Date(`${iso}T00:00:00Z`)
  at.setUTCDate(at.getUTCDate() + n)
  return at.toISOString().slice(0, 10)
}

function daySpan(from, to) {
  const out = []
  for (let at = from; at <= to; at = dayStep(at, 1)) out.push(at)
  return out
}

function dayName(iso) {
  const at = new Date(`${iso}T00:00:00Z`)
  return `${at.toLocaleString("en-US", { month: "short", timeZone: "UTC" })} ${at.getUTCDate()}`
}

export default class extends Controller {
  static values = {
    kind: String, data: Object, height: Number, pct: Boolean,
    stacked: Boolean, days: Boolean, spark: Boolean, rule: Object, splits: Array,
    voids: Array, partial: Array, partialNote: String, notes: Array, caps: Array
  }

  connect() {
    this.gid = `cg${++seq}`
    this.shown = this.kindValue || "bars"
    this.at = null
    this.wide = 0
    this.build()

    const chart = this.element.querySelector(".chart")
    if (!chart) return

    this.watcher = new ResizeObserver(() => this.measure())
    this.watcher.observe(chart)
  }

  disconnect() {
    this.watcher?.disconnect()
  }

  get rows() {
    const { labels = [], datasets = [] } = this.dataValue
    const blanked = new Map((this.hasVoidsValue ? this.voidsValue : [])
      .map((v) => [Number(v.at), v.note || ""]))
    const notes = this.hasNotesValue ? this.notesValue : []
    const given = labels.map((label, i) => {
      const key = Array.isArray(label) ? label[0] : label
      const row = { label: key, key }
      datasets.forEach((set, s) => {
        row[`s${s}`] = set.data[i]
        if (set.counts) row[`c${s}`] = set.counts[i]
      })
      if (notes[i]) row.tip = notes[i]
      if (blanked.has(i)) {
        row.gap = true
        row.why = blanked.get(i)
      }
      return row
    })
    if (!this.daysValue || !given.length) return given

    const dated = given.filter((row) => ISO.test(row.key))
    if (dated.length < 2) return given

    const held = new Map(dated.map((row) => [row.key, row]))
    const keys = dated.map((row) => row.key).sort()
    return daySpan(keys[0], keys[keys.length - 1]).map((day) => {
      const row = held.get(day)
      if (row) return { ...row, label: dayName(day) }

      const gap = { label: dayName(day), key: day, gap: true }
      datasets.forEach((_, s) => { gap[`s${s}`] = null; gap[`c${s}`] = null })
      return gap
    })
  }

  get series() {
    return (this.dataValue.datasets || []).map((set, i) => ({
      k: `s${i}`, c: `c${i}`, n: set.label, ink: INK[i % INK.length], own: set.color,
      ghost: !!set.ghost
    }))
  }

  get height() {
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 214
  }

  get line() {
    return this.shown === "line"
  }

  build() {
    const series = this.series
    if (!this.rows.length || !series.length) return

    this.element.classList.toggle("chart-spark", this.sparkValue)
    this.element.innerHTML = `${this.head(series)}<div class="chart tipped" tabindex="0"
      data-action="mousemove->chart#track mouseleave->chart#clear keydown->chart#key"
      ><div class="tip"></div><span class="chart-say" aria-live="polite"></span></div>`
    this.wide = 0
    this.measure()
  }

  measure() {
    const chart = this.element.querySelector(".chart")
    const wide = chart ? chart.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(chart, wide)
  }

  head(series) {
    const swatch = (s) =>
      `<span><i class="${this.paint(s)}${s.ghost ? " ghost" : ""}"${
        this.tint(s)}></i>${esc(s.n)}</span>`
    if (series.length < 2 || this.sparkValue) return ""

    const order = this.stack ? series.slice().reverse() : series
    return `<div class="chart-legend">${order.map(swatch).join("")}</div>`
  }

  paint(s) {
    return `ser-${s.ink}`
  }

  tint(s) {
    return s.own ? ` style="color:${esc(s.own)}"` : ""
  }

  tick(v) {
    return this.pctValue ? `${Math.round(v)}%` : axl(v)
  }

  said(v) {
    if (v == null) return "n/a"
    return this.pctValue ? `${Number(v).toFixed(1)}%` : F(v)
  }

  get pad() {
    return this.sparkValue ? { l: 1, r: 1, t: 3, b: 3 } : PAD
  }

  get stack() {
    return this.stackedValue && !this.line && this.series.length > 1
  }

  sum(row, series) {
    return series.reduce((at, s) => at + (row[s.k] == null ? 0 : Number(row[s.k])), 0)
  }

  scales(rows, series, wide) {
    const high = this.height
    const line = this.line
    const pad = this.pad

    const x = scaleBand()
      .domain(rows.map((_, i) => i))
      .range([pad.l, wide - pad.r])
      .padding(line ? 0 : 0.26)

    const seen = this.stack
      ? rows.map((r) => this.sum(r, series))
      : rows.flatMap((r) => series.map((s) => r[s.k])).filter((v) => v != null)
    let lo = 0
    let hi = seen.length ? Math.max(...seen) : 0

    if (this.pctValue) {
      lo = 0
      hi = 100
    } else if (line && seen.length) {
      const least = Math.min(...seen)
      if (this.sparkValue) lo = least
      else if (least > 0 && hi > 0 && (hi - least) / hi < 0.6) lo = least
    }
    if (this.hasRuleValue && this.ruleValue.at != null && !this.pctValue) {
      hi = Math.max(hi, Number(this.ruleValue.at))
    }
    if (hi <= lo) hi = lo + 1

    const y = scaleLinear().domain([lo, hi]).range([high - pad.b, pad.t])
    if (!this.pctValue && !this.sparkValue) y.nice(4)

    return { x, y, lo: y.domain()[0], line, high, pad }
  }

  shownLabels(rows, wide) {
    const room = Math.max(2, Math.floor((wide - PAD.l - PAD.r) / LABEL_ROOM))
    const every = Math.max(1, Math.ceil(rows.length / room))
    const last = rows.length - 1
    if (every === 1) return new Set(rows.map((_, i) => i))

    const show = new Set()
    for (let i = 0; i <= last; i += every) show.add(i)
    const top = Math.max(...show)
    if (last - top <= Math.ceil(every / 2)) show.delete(top)
    show.add(last)
    return show
  }

  draw(chart, wide) {
    const rows = this.rows
    const series = this.series
    const { x, y, lo, line, high, pad } = this.scales(rows, series, wide)
    const mid = (i) => x(i) + x.bandwidth() / 2
    const ticks = this.pctValue ? [0, 50, 100] : y.ticks(high < 160 ? 3 : 4)
    const right = wide - pad.r
    const floor = y(lo)

    const grid = this.sparkValue ? "" : ticks.map((v) => {
      const at = y(v).toFixed(1)
      return `<line class="grid" x1="${pad.l}" y1="${at}" x2="${right}" y2="${at}"/>` +
        `<text class="ax" x="${pad.l - 8}" y="${(y(v) + 3.5).toFixed(1)}" text-anchor="end">${
          this.tick(v)}</text>`
    }).join("")

    const gaps = rows.map((r, i) => r.gap
      ? `<rect class="hole" x="${x(i).toFixed(1)}" y="${pad.t}" width="${
        Math.max(1, x.step()).toFixed(1)}" height="${(floor - pad.t).toFixed(1)}"/>`
      : "").join("")

    const rule = this.hasRuleValue && this.ruleValue.at != null
      ? `<line class="mark-rule" x1="${pad.l}" y1="${y(this.ruleValue.at).toFixed(1)}" x2="${
        right}" y2="${y(this.ruleValue.at).toFixed(1)}"/>` + (this.ruleValue.label
        ? `<text class="ax rule-say" x="${right}" y="${
          (y(this.ruleValue.at) - 5).toFixed(1)}" text-anchor="end">${
          esc(this.ruleValue.label)}</text>`
        : "")
      : ""

    const splits = (this.hasSplitsValue ? this.splitsValue : []).map((split) => {
      const after = Number(split.after)
      if (!(after >= 0) || after >= rows.length - 1) return ""

      const at = (x(after) + x.bandwidth() + x(after + 1)) / 2
      return `<line class="split" x1="${at.toFixed(1)}" y1="${pad.t}" x2="${at.toFixed(1)}" y2="${
        floor}"/>` + (split.label
        ? `<text class="ax split-say" x="${(at + 5).toFixed(1)}" y="${pad.t + 9}">${
          esc(split.label)}</text>`
        : "")
    }).join("")

    const flagged = new Set((this.hasPartialValue ? this.partialValue : []).map(Number))
    const marks = this.line || this.sparkValue ? "" : rows.map((r, i) => {
      if (!flagged.has(i)) return ""

      let bw = x.bandwidth()
      let at = x(i)
      if (bw > BAR_CAP) {
        at += (bw - BAR_CAP) / 2
        bw = BAR_CAP
      }
      const total = this.stack ? this.sum(r, series)
        : Math.max(...series.map((s) => r[s.k] == null ? 0 : Number(r[s.k])))
      const top = y(total)
      if (!(floor - top > 0)) return ""

      return `<rect class="partial-mark" x="${(at - 1.5).toFixed(1)}" y="${(top - 1.5).toFixed(1)}"
        width="${(bw + 3).toFixed(1)}" height="${(floor - top + 1.5).toFixed(1)}" rx="3"/>`
    }).join("")

    const shown = this.sparkValue ? new Set() : this.shownLabels(rows, wide)
    const names = rows.map((r, i) => shown.has(i)
      ? `<text class="ax" x="${mid(i).toFixed(1)}" y="${high - pad.b + 16}" text-anchor="middle">${
        esc(r.label)}</text>`
      : "").join("")

    const body = line
      ? this.drawLine(rows, series, { x, y, mid, lo, floor })
      : this.drawBars(rows, series, { x, y, floor })

    const defs = line && series.length === 1 && (lo === 0 || this.sparkValue)
      ? `<linearGradient id="${this.gid}" x1="0" y1="0" x2="0" y2="1">
          <stop class="top ${this.paint(series[0])}"${this.tint(series[0])} offset="0"/>
          <stop class="bot ${this.paint(series[0])}"${this.tint(series[0])} offset="1"/>
          </linearGradient>`
      : ""

    const cursor = line
      ? `<line class="cur" x1="0" y1="${pad.t}" x2="0" y2="${floor}" opacity="0"/>` +
        series.map((s) => `<circle class="dot ${this.paint(s)}"${this.tint(s)} data-s="${s.k}" r="${
          this.sparkValue ? 3.2 : 4.5}" fill="currentColor" opacity="0"/>`).join("")
      : ""

    const base = this.sparkValue
      ? ""
      : `<line class="base" x1="${pad.l}" y1="${floor}" x2="${right}" y2="${floor}"/>`

    chart.querySelector("svg")?.remove()
    chart.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary(rows, series))}"><defs>${defs}</defs>${gaps}${grid}` +
      `${base}${rule}${body}${marks}${splits}${cursor}${names}</svg>`)

    this.geom = {
      x, y, mid, lo, line, wide, high, rows, series, floor, pad,
      tops: rows.map((r) => this.stack
        ? y(this.sum(r, series))
        : Math.min(...series.map((s) => r[s.k] == null ? high : y(r[s.k]))))
    }
    if (this.at != null) this.show(clamp(this.at, 0, rows.length - 1))
  }

  drawBars(rows, series, { x, y, floor }) {
    if (this.stack) return this.drawStack(rows, series, { x, y, floor })

    const sub = scaleBand()
      .domain(series.map((s) => s.k))
      .range([0, x.bandwidth()])
      .padding(series.length > 1 ? 0.16 : 0)

    return rows.map((r, i) => {
      const bars = series.map((s) => {
        const v = r[s.k]
        if (v == null) return ""

        let wide = sub.bandwidth()
        let at = x(i) + sub(s.k)
        if (wide > BAR_CAP) {
          at += (wide - BAR_CAP) / 2
          wide = BAR_CAP
        }
        const top = y(v)
        return `<path class="${this.paint(s)}"${this.tint(s)} fill="currentColor" d="${
          topBar(at, top, wide, floor - top, BAR_R)}"/>`
      }).join("")

      return `<g class="mark" data-i="${i}">${bars}</g>`
    }).join("")
  }

  drawStack(rows, series, { x, y, floor }) {
    const caps = this.hasCapsValue ? this.capsValue : []
    const ceiling = this.pad.t + 9

    return rows.map((r, i) => {
      let wide = x.bandwidth()
      let at = x(i)
      if (wide > BAR_CAP) {
        at += (wide - BAR_CAP) / 2
        wide = BAR_CAP
      }

      let below = 0
      const bars = series.map((s, s_i) => {
        const v = r[s.k]
        if (v == null) return ""

        const under = y(below)
        below += Number(v)
        const top = y(below)
        const tall = Math.max(0, under - top - (s_i ? SEG_GAP : 0))
        if (!(tall > 0)) return ""

        const cap = s_i === series.length - 1 ? BAR_R : 0
        return `<path class="${this.paint(s)}"${this.tint(s)} fill="currentColor" d="${
          topBar(at, top, wide, tall, cap)}"/>`
      }).reverse().join("")

      const cap = caps[i]
      const say = cap == null || cap.v == null ? "" :
        `<text class="cap" x="${(at + wide / 2).toFixed(1)}" y="${
          Math.max(ceiling, y(Number(cap.v)) - 7).toFixed(1)}" text-anchor="middle">${
          esc(cap.t)}</text>`

      return `<g class="mark" data-i="${i}">${bars}${say}</g>`
    }).join("")
  }

  drawLine(rows, series, { mid, y, lo, floor }) {
    const bend = this.daysValue ? curveLinear : curveMonotoneX
    const pts = (s) => rows.map((r, i) => ({ i, v: r[s.k] }))
    const path = lineOf().defined((d) => d.v != null).x((d) => mid(d.i)).y((d) => y(d.v))
      .curve(bend)
    const under = areaOf().defined((d) => d.v != null).x((d) => mid(d.i)).y0(floor)
      .y1((d) => y(d.v)).curve(bend)
    const solid = series.filter((s) => !s.ghost)
    const wash = solid.length === 1 && (lo === 0 || this.sparkValue)

    return series.map((s) => {
      const seen = pts(s)
      const fill = wash && !s.ghost
        ? `<path class="wash" fill="url(#${this.gid})" d="${under(seen)}"/>` : ""
      const dash = s.ghost ? ' stroke-dasharray="5 4"' : ""
      return `${fill}<path class="${this.paint(s)}"${this.tint(s)} fill="none" stroke="currentColor"
        stroke-width="${s.ghost ? 1.5 : 2}"${dash} stroke-linejoin="round" stroke-linecap="round"
        d="${path(seen)}"/>`
    }).join("")
  }

  summary(rows, series) {
    const title = this.element.closest(".card")?.querySelector(".card-title")?.textContent?.trim()
    const what = series.map((s) => s.n).join(" and ")
    const shape = this.sparkValue ? "trend" : this.stack ? "stacked bar chart"
      : this.line ? "line chart" : "bar chart"
    const seen = rows.flatMap((r) => series.map((s) => r[s.k])).filter((v) => v != null)
    const holes = rows.filter((r) => r.gap).length
    const range = seen.length
      ? `, low ${this.said(Math.min(...seen))}, high ${this.said(Math.max(...seen))}`
      : ""
    const latest = rows.length && series.length
      ? `, latest ${this.said(rows[rows.length - 1][series[0].k])}`
      : ""
    const unit = this.daysValue ? "day" : "point"
    const missing = holes ? `, ${holes} ${unit}${holes > 1 ? "s" : ""} not measurable` : ""
    return `${title || what} ${shape}, ${rows.length} points, ${rows[0].label} to ${
      rows[rows.length - 1].label}${range}${latest}${missing}`
  }

  track(event) {
    const g = this.geom
    if (!g) return

    const box = this.element.querySelector(".chart").getBoundingClientRect()
    const mx = event.clientX - box.left
    const my = event.clientY - box.top
    if (mx < g.pad.l || mx > g.wide - g.pad.r || my > g.high - g.pad.b) return this.clear()

    const i = clamp(Math.floor((mx - g.pad.l) / g.x.step()), 0, g.rows.length - 1)
    this.show(i)
  }

  key(event) {
    const g = this.geom
    if (!g) return

    const last = g.rows.length - 1
    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key]
    let next = this.at

    if (step) next = this.at == null ? (step > 0 ? 0 : last) : clamp(this.at + step, 0, last)
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
    const row = g.rows[i]
    this.at = i

    const lines = row.gap
      ? `<div class="row"><i class="hole-dot"></i>${
        esc(row.why || "not fetched")}<b>n/a</b></div>`
      : g.series.map((s) => row[s.k] == null ? "" :
        `<div class="row"><i class="${this.paint(s)}"${this.tint(s)}></i>${esc(s.n)}<b>${
          this.said(row[s.k])}${row[s.c] == null ? "" : ` <u>${F(row[s.c])}</u>`}</b></div>`)
        .join("")

    const whole = this.stack && !row.gap && !this.pctValue
      ? `<div class="row row-sum"><i></i>total<b>${this.said(this.sum(row, g.series))}</b></div>`
      : ""

    const short = this.hasPartialValue && this.partialValue.map(Number).includes(i)
      ? `<div class="row row-note"><i class="hole-dot"></i>${
        esc(this.partialNoteValue || "period not complete")}</div>`
      : ""

    const said = row.tip
      ? `<div class="row row-note"><i></i>${esc(row.tip)}</div>`
      : ""

    const note = this.hasRuleValue && this.ruleValue.note
      ? `<div class="row row-note"><i></i>${esc(this.ruleValue.note)}</div>`
      : ""

    const tip = chart.querySelector(".tip")
    tip.innerHTML = `<div class="t">${esc(row.label)}</div>${lines}${whole}${said}${short}${note}`
    tip.classList.add("on")

    const at = g.mid(i)
    const tipWide = tip.offsetWidth || 190
    const bandL = g.line ? at : g.x(i)
    const bandR = g.line ? at : g.x(i) + g.x.bandwidth()

    let left = bandR + 12
    if (left + tipWide > g.wide) left = bandL - 12 - tipWide
    if (left < 0) left = clamp(at - tipWide / 2, 0, Math.max(0, g.wide - tipWide))

    tip.style.left = `${left}px`
    tip.style.top = `${g.pad.t}px`

    chart.querySelectorAll(".mark").forEach((mark) =>
      mark.classList.toggle("fade", +mark.dataset.i !== i))

    const cur = chart.querySelector(".cur")
    if (cur) {
      cur.setAttribute("x1", at)
      cur.setAttribute("x2", at)
      cur.setAttribute("opacity", "0.6")
      chart.querySelectorAll(".dot").forEach((dot) => {
        const v = row[dot.dataset.s]
        if (v == null) return dot.setAttribute("opacity", "0")

        dot.setAttribute("cx", at)
        dot.setAttribute("cy", g.y(v))
        dot.setAttribute("opacity", "1")
      })
    }

    chart.querySelector(".chart-say").textContent = row.gap
      ? `${row.label}, ${row.why || "not fetched"}`
      : `${row.label}, ${g.series.map((s) => `${s.n} ${this.said(row[s.k])}`).join(", ")}${
        this.stack ? `, total ${this.said(this.sum(row, g.series))}` : ""}`
  }

  clear() {
    const chart = this.element.querySelector(".chart")
    if (!chart) return

    this.at = null
    chart.querySelector(".tip")?.classList.remove("on")
    chart.querySelector(".cur")?.setAttribute("opacity", "0")
    chart.querySelectorAll(".dot").forEach((dot) => dot.setAttribute("opacity", "0"))
    chart.querySelectorAll(".mark").forEach((mark) => mark.classList.remove("fade"))
    const say = chart.querySelector(".chart-say")
    if (say) say.textContent = ""
  }
}
