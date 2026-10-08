import { Controller } from "@hotwired/stimulus"
import { scaleBand, scaleLinear } from "d3-scale"
import { line as lineOf, area as areaOf, curveMonotoneX, curveLinear } from "d3-shape"

let seq = 0

const INK = [1, 2, 3, 4, 5, 0]

const PAD = { l: 44, r: 8, t: 20, b: 34 }

const BAR_CAP = 72
const BAR_R = 6
const PILL_H = 22
const SEG_GAP = 2
const AX_SAY_X = 26
const AX_SAY_Y = 22

const RULER = typeof document === "undefined"
  ? null
  : document.createElement("canvas").getContext("2d")

function axWide(text) {
  if (!RULER) return String(text).length * 6

  RULER.font = '12px Geist, ui-sans-serif, system-ui, sans-serif'
  return RULER.measureText(String(text)).width
}

const BIN = /^([<>])?(\d+)(?:-(\d+))?(\+)?$/

const kilo = (n) => (n >= 1000 ? `${+(n / 1000).toFixed(n % 1000 >= 100 ? 1 : 0)}k` : String(n))

function binLabels(rows) {
  const parts = rows.map((r) => BIN.exec(String(r.label)))
  if (!parts.length || parts.some((m) => !m)) return null

  const ranged = parts.map(([, side, a, b, plus]) =>
    `${side || ""}${kilo(Number(a))}${b ? `-${kilo(Number(b))}` : ""}${plus ? "+" : ""}`)
  const floors = parts.map(([, side, a, , plus]) => `${side || ""}${kilo(Number(a))}${plus ? "+" : ""}`)
  return [ranged, floors]
}

const F = (n) => (n == null ? "n/a" : Number(n).toLocaleString("en-US"))

const axl = (v) =>
  Math.abs(v) >= 1000 ? `${+(v / 1000).toFixed(v % 1000 ? 1 : 0)}k` : `${Math.round(v)}`

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)

function topBar(x, y, w, h, r) {
  if (!(h > 0) || !(w > 0)) return ""

  const k = Math.min(r, w / 2, h / 2)
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
    kind: String, data: Object, height: Number, pct: Boolean, pctFit: Boolean,
    stacked: Boolean, days: Boolean, spark: Boolean, rule: Object, splits: Array,
    voids: Array, partial: Array, partialNote: String, notes: Array, caps: Array, nokey: Boolean,
    xlabel: String, ylabel: String
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
      ghost: !!set.ghost, over: !!set.over
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
    const rows = this.rows
    if (!rows.length || !series.length) return

    if (!this.sparkValue && rows.every((r) => series.every((s) => !Number(r[s.k])))) {
      this.element.innerHTML = `<div class="chart-empty" style="min-height:${this.height}px">Nothing in this range</div>`
      return
    }

    this.fresh = true
    this.element.classList.toggle("chart-spark", this.sparkValue)
    this.element.innerHTML = `${this.head(series)}<div class="chart tipped" tabindex="0"
      data-action="mousemove->chart#track mouseleave->chart#clear keydown->chart#key"
      ><div class="tip"></div><span class="chart-caption" aria-live="polite"></span></div>`
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
    if (series.length < 2 || this.sparkValue || this.nokeyValue) return ""

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
    if (!this.pctValue) return axl(v)

    return this.fineTicks ? `${Number(v).toFixed(1)}%` : `${Math.round(v)}%`
  }

  format(v) {
    if (v == null) return "n/a"
    return this.pctValue ? `${Number(v).toFixed(1)}%` : F(v)
  }

  get overs() {
    return this.line ? [] : this.series.filter((s) => s.over)
  }

  get pad() {
    if (this.sparkValue) return { l: 1, r: 1, t: 3, b: 3 }

    const text = {
      ...PAD,
      r: PAD.r + (this.overs.length ? 34 : 0),
      l: PAD.l + (this.xlabelValue || this.ylabelValue ? AX_SAY_Y : 0),
      b: PAD.b + (this.xlabelValue ? AX_SAY_X : 0)
    }
    return text
  }

  get stack() {
    return this.stackedValue && !this.line && this.series.filter((s) => !s.over).length > 1
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

    const pinned = this.pctValue && !this.pctFitValue
    if (pinned) {
      lo = 0
      hi = 100
    } else if (line && seen.length) {
      const least = Math.min(...seen)
      if (this.sparkValue) lo = least
      else if (least > 0 && hi > 0 && (hi - least) / hi < 0.6) lo = least
    }
    if (this.hasRuleValue && this.ruleValue.at != null && !pinned) {
      hi = Math.max(hi, Number(this.ruleValue.at))
    }
    if (hi <= lo) hi = lo + 1

    const y = scaleLinear().domain([lo, hi]).range([high - pad.b, pad.t])
    if (!pinned && !this.sparkValue) y.nice(4)

    return { x, y, lo: y.domain()[0], line, high, pad, pinned }
  }

  shownLabels(rows, wide) {
    const band = (wide - PAD.l - PAD.r) / rows.length
    const widest = rows.reduce((mx, r) => Math.max(mx, axWide(r.label)), 0)
    if (widest + 12 <= band) return { show: this.everyNth(rows.length, 1) }

    const sets = this.daysValue || this.line ? [] : (binLabels(rows) || [])
    const fits = sets.find((names) => names.every((name) => axWide(name) + 12 <= band))
    if (fits) return { show: this.everyNth(rows.length, 1), names: fits }

    const names = sets[sets.length - 1]
    const room = names ? Math.max(...names.map(axWide)) : widest
    return { show: this.everyNth(rows.length, Math.max(1, Math.ceil((room + 16) / band))), names }
  }

  everyNth(count, every) {
    const show = new Set()
    for (let i = 0; i < count; i += every) show.add(i)
    return show
  }

  draw(chart, wide) {
    const rows = this.rows
    const all = this.series
    const overs = this.overs
    const series = overs.length ? all.filter((s) => !s.over) : all
    const labels = this.sparkValue ? { show: new Set() } : this.shownLabels(rows, wide)
    const { x, y, lo, line, high, pad, pinned } = this.scales(rows, series, wide)
    const mid = (i) => x(i) + x.bandwidth() / 2
    const span = y.domain()[1] - y.domain()[0]
    this.fineTicks = !pinned && this.pctValue && span < 5
    const whole = rows.every((r) => series.every((s) => r[s.k] == null || Number.isInteger(Number(r[s.k]))))
    const ticks = pinned ? [0, 50, 100]
      : y.ticks(high < 160 ? 3 : 4).filter((v) => !whole || Number.isInteger(v))
    const right = wide - pad.r
    const floor = y(lo)

    const grid = this.sparkValue ? "" : `<g class="grid-set" mask="url(#${this.gid}-fade)">${
      ticks.map((v) => {
        const at = y(v).toFixed(1)
        return `<line class="grid" x1="${pad.l}" y1="${at}" x2="${right}" y2="${at}"/>`
      }).join("")}</g>` + ticks.map((v) =>
      `<text class="ax" x="${pad.l - 8}" y="${(y(v) + 3.5).toFixed(1)}" text-anchor="end">${
        this.tick(v)}</text>`).join("")

    const gaps = rows.map((r, i) => r.gap
      ? `<rect class="donut-hole" x="${x(i).toFixed(1)}" y="${pad.t}" width="${
        Math.max(1, x.step()).toFixed(1)}" height="${(floor - pad.t).toFixed(1)}"/>`
      : "").join("")

    const rule = this.hasRuleValue && this.ruleValue.at != null
      ? `<line class="mark-rule" x1="${pad.l}" y1="${y(this.ruleValue.at).toFixed(1)}" x2="${
        right}" y2="${y(this.ruleValue.at).toFixed(1)}"/>` + (this.ruleValue.label
        ? `<text class="ax rule-note" x="${right}" y="${
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
        ? `<text class="ax split-note" x="${(at + 5).toFixed(1)}" y="${pad.t + 9}">${
          esc(split.label)}</text>`
        : "")
    }).join("")

    const flagged = (this.hasPartialValue ? this.partialValue : []).map(Number)
      .filter((i) => i >= 0 && i < rows.length)
    const lip = (x.step() - x.bandwidth()) / 2
    const runs = [...new Set(flagged)].sort((a, b) => a - b).reduce((all, i) => {
      const last = all[all.length - 1]
      if (last && i === last[1] + 1) last[1] = i
      else all.push([i, i])
      return all
    }, [])
    const marks = this.sparkValue ? "" : runs.map(([from, to]) => {
      const left = Math.max(pad.l, x(from) - lip)
      const width = Math.min(right, x(to) + x.bandwidth() + lip) - left
      return `<rect class="partial-area" x="${left.toFixed(1)}" y="${pad.t}" width="${
        width.toFixed(1)}" height="${(floor - pad.t).toFixed(1)}" fill="url(#${this.gid}-hatch)"/>`
    }).join("")

    const weekends = !this.daysValue || this.sparkValue ? "" : rows.map((r, i) => {
      if (!ISO.test(r.key)) return ""
      const day = new Date(`${r.key}T00:00:00Z`).getUTCDay()
      if (day !== 0 && day !== 6) return ""
      return `<rect class="weekend" x="${(x(i) - lip).toFixed(1)}" y="${pad.t}" width="${
        x.step().toFixed(1)}" height="${(floor - pad.t).toFixed(1)}"/>`
    }).join("")

    let kept = -Infinity
    const names = rows.map((r, i) => {
      if (!labels.show.has(i)) return ""

      const at = mid(i)
      const text = labels.names ? labels.names[i] : r.label

      const wideness = axWide(text)
      const anchor = at - wideness / 2 < 2
        ? "start" : at + wideness / 2 > wide - 2 ? "end" : "middle"
      const x = anchor === "start" ? 2 : anchor === "end" ? wide - 2 : at
      const left = anchor === "start" ? x : anchor === "end" ? x - wideness : x - wideness / 2
      if (left < kept + 12) return ""

      kept = left + wideness
      return `<text class="ax xtick" data-x="${at.toFixed(1)}" x="${x.toFixed(1)}" y="${
        high - pad.b + 22}" text-anchor="${anchor}">${esc(text)}</text>`
    }).join("")

    const body = line
      ? this.drawLine(rows, series, { x, y, mid, lo, floor })
      : this.drawBars(rows, series, { x, y, floor })

    const seenOver = rows.flatMap((r) => overs.map((s) => r[s.k])).filter((v) => v != null)
    const y2 = overs.length
      ? scaleLinear().domain([0, Math.max(1, ...seenOver.map(Number))]).range([floor, pad.t]).nice(3)
      : null
    const over = overs.length ? this.drawOver(rows, overs, { mid, y2, floor }) : ""
    const rightAxis = y2
      ? y2.ticks(3).filter((v) => Number.isInteger(v)).map((v) =>
        `<text class="ax ax-over" x="${(right + 8).toFixed(1)}" y="${(y2(v) + 3.5).toFixed(1)}">${
          axl(v)}</text>`).join("")
      : ""

    const wash = line && series.length === 1 && (lo === 0 || this.sparkValue)
      ? `<linearGradient id="${this.gid}" x1="0" y1="0" x2="0" y2="1">
          <stop class="top ${this.paint(series[0])}"${this.tint(series[0])} offset="0"/>
          <stop class="bot ${this.paint(series[0])}"${this.tint(series[0])} offset="1"/>
          </linearGradient>`
      : ""
    const edge = `<linearGradient id="${this.gid}-edge" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stop-color="#fff" stop-opacity="0"/>
        <stop offset="0.06" stop-color="#fff" stop-opacity="1"/>
        <stop offset="0.94" stop-color="#fff" stop-opacity="1"/>
        <stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
      <mask id="${this.gid}-fade" maskUnits="userSpaceOnUse" x="0" y="0" width="${wide}" height="${high}">
        <rect x="${pad.l}" y="0" width="${(right - pad.l).toFixed(1)}" height="${high}"
          fill="url(#${this.gid}-edge)"/></mask>`
    const overWash = overs.map((s, n) => `<linearGradient id="${this.gid}-o${n}" x1="0" y1="0" x2="0" y2="1">
        <stop class="top ${this.paint(s)}"${this.tint(s)} offset="0"/>
        <stop class="bot ${this.paint(s)}"${this.tint(s)} offset="1"/></linearGradient>`).join("")
    const hatch = `<pattern id="${this.gid}-hatch" width="6" height="6" patternUnits="userSpaceOnUse"
        patternTransform="rotate(45)"><line class="hatch" x1="0" y1="0" x2="0" y2="6"/></pattern>`
    const defs = wash + edge + overWash + hatch

    const cursor = (this.sparkValue && !line) ? "" :
      `<line class="cur" x1="0" y1="${pad.t}" x2="0" y2="${floor}" opacity="0"/>` +
      (line
        ? series.map((s) => `<circle class="dot ${this.paint(s)}"${this.tint(s)} data-s="${s.k}" r="${
          this.sparkValue ? 3.2 : 4}" fill="currentColor" opacity="0"/>`).join("")
        : "")
    const overDots = overs.map((s) => `<circle class="dot ${this.paint(s)}"${this.tint(s)} data-s="${
      s.k}" data-axis="2" r="4" fill="currentColor" opacity="0"/>`).join("")

    const pill = this.sparkValue ? "" :
      `<g class="x-pill" opacity="0"><rect y="${(high - pad.b + 6).toFixed(1)}" height="${PILL_H}"
        rx="6" width="0"/><text y="${(high - pad.b + 6 + PILL_H / 2 + 4).toFixed(1)}"
        text-anchor="middle"></text></g>`

    const base = this.sparkValue
      ? ""
      : `<line class="base" mask="url(#${this.gid}-fade)" x1="${pad.l}" y1="${floor}" x2="${
        right}" y2="${floor}"/>`

    const says = this.sparkValue ? "" : [
      this.xlabelValue
        ? `<text class="ax" x="${((pad.l + right) / 2).toFixed(1)}" y="${high - 9}"
          text-anchor="middle">${esc(this.xlabelValue)}</text>`
        : "",
      this.ylabelValue
        ? `<text class="ax" transform="translate(15 ${((pad.t + floor) / 2).toFixed(1)}) rotate(-90)"
          text-anchor="middle">${esc(this.ylabelValue)}</text>`
        : ""
    ].join("")

    chart.querySelector("svg")?.remove()
    chart.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary(rows, series))}"><defs>${defs}</defs>${weekends}${marks}${gaps}${
        grid}` +
      `${base}${rule}${cursor}${body}${over}${overDots}${splits}${names}${rightAxis}${says}${
        pill}</svg>`)

    if (this.fresh) {
      this.fresh = false
      chart.classList.add("is-entering")
      clearTimeout(this.entered)
      this.entered = setTimeout(() => chart.classList.remove("is-entering"), 1400)
    }

    this.geom = {
      x, y, y2, mid, lo, line, wide, high, rows, series: all, bars: series, floor, pad,
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
        if (Number(v) === 0) {
          return `<rect class="${this.paint(s)}"${this.tint(s)} fill="currentColor" opacity="0.45"
            x="${at.toFixed(1)}" y="${(floor - 2).toFixed(1)}"
            width="${wide.toFixed(1)}" height="2" rx="1"/>`
        }
        const tall = Math.max(floor - y(v), 2)
        return `<path class="bar ${this.paint(s)}"${this.tint(s)} fill="currentColor" d="${
          topBar(at, floor - tall, wide, tall, Math.min(BAR_R, wide / 2))}"/>`
      }).join("")

      return `<g class="mark" data-i="${i}" style="--i:${i}">${bars}</g>`
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

        const cap = s_i === series.length - 1 ? Math.min(BAR_R, wide / 2) : 0
        return `<path class="bar ${this.paint(s)}"${this.tint(s)} fill="currentColor" d="${
          topBar(at, top, wide, tall, cap)}"/>`
      }).reverse().join("")

      const cap = caps[i]
      const say = cap == null || cap.v == null ? "" :
        `<text class="cap" x="${(at + wide / 2).toFixed(1)}" y="${
          Math.max(ceiling, y(Number(cap.v)) - 7).toFixed(1)}" text-anchor="middle">${
          esc(cap.t)}</text>`

      return `<g class="mark" data-i="${i}" style="--i:${i}">${bars}${say}</g>`
    }).join("")
  }

  drawLine(rows, series, { mid, y, lo, floor }) {
    const bend = curveMonotoneX
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
        ? `<path class="wash" fill="url(#${this.gid})" mask="url(#${this.gid}-fade)" d="${
          under(seen)}"/>` : ""
      const dash = s.ghost ? ' stroke-dasharray="5 4"' : ' pathLength="1"'
      return `${fill}${this.bridge(seen, s, mid, y)}<path class="${s.ghost ? "" : "stroke-line "}${
        this.paint(s)}"${this.tint(s)} fill="none" stroke="currentColor"
        stroke-width="${s.ghost ? 1.5 : 2}"${dash} stroke-linejoin="round" stroke-linecap="round"
        d="${path(seen)}"/>${this.alone(seen, s, mid, y)}`
    }).join("")
  }

  drawOver(rows, overs, { mid, y2, floor }) {
    const bend = curveMonotoneX
    return overs.map((s, n) => {
      const seen = rows.map((r, i) => ({ i, v: r[s.k] }))
      const path = lineOf().defined((d) => d.v != null).x((d) => mid(d.i)).y((d) => y2(d.v)).curve(bend)
      const under = areaOf().defined((d) => d.v != null).x((d) => mid(d.i)).y0(floor)
        .y1((d) => y2(d.v)).curve(bend)
      return `<path class="wash wash-over" fill="url(#${this.gid}-o${n})" mask="url(#${this.gid}-fade)"
          d="${under(seen)}"/>` +
        `<path class="stroke-line ${this.paint(s)}"${this.tint(s)} pathLength="1" fill="none"
          stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"
          d="${path(seen)}"/>`
    }).join("")
  }

  bridge(seen, s, mid, y) {
    const at = seen.filter((d) => d.v != null)
    const spans = at.slice(1)
      .map((d, k) => [at[k], d])
      .filter(([a, b]) => b.i - a.i > 1)
      .map(([a, b]) => `M${mid(a.i)},${y(a.v)}L${mid(b.i)},${y(b.v)}`)
    if (!spans.length) return ""

    return `<path class="${this.paint(s)}"${this.tint(s)} fill="none" stroke="currentColor"
      stroke-width="${s.ghost ? 1.5 : 2}" stroke-dasharray="2 3" stroke-linecap="round"
      opacity="0.5" d="${spans.join("")}"/>`
  }

  alone(seen, s, mid, y) {
    return seen.filter((d, i) =>
      d.v != null && seen[i - 1]?.v == null && seen[i + 1]?.v == null
    ).map((d) =>
      `<circle class="${this.paint(s)}"${this.tint(s)} fill="currentColor" stroke="none"
        cx="${mid(d.i)}" cy="${y(d.v)}" r="${s.ghost ? 1.5 : 2}"/>`
    ).join("")
  }

  summary(rows, series) {
    const title = this.element.closest(".card")?.querySelector(".card-title")?.textContent?.trim()
    const what = series.map((s) => s.n).join(" and ")
    const shape = this.sparkValue ? "trend" : this.stack ? "stacked bar chart"
      : this.line ? "line chart" : "bar chart"
    const seen = rows.flatMap((r) => series.map((s) => r[s.k])).filter((v) => v != null)
    const holes = rows.filter((r) => r.gap).length
    const range = seen.length
      ? `, low ${this.format(Math.min(...seen))}, high ${this.format(Math.max(...seen))}`
      : ""
    const latest = rows.length && series.length
      ? `, latest ${this.format(rows[rows.length - 1][series[0].k])}`
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
      ? `<div class="row"><i class="donut-hole-dot"></i>${
        esc(row.why || "not fetched")}<b>n/a</b></div>`
      : g.series.map((s) => row[s.k] == null ? "" :
        `<div class="row"><i class="${this.paint(s)}"${this.tint(s)}></i>${esc(s.n)}<b><span>${
          this.format(row[s.k])}</span>${row[s.c] == null ? "" : `<u>${F(row[s.c])}</u>`}</b></div>`)
        .join("")

    const whole = this.stack && !row.gap && !this.pctValue
      ? `<div class="row row-sum"><i></i>total<b><span>${
        this.format(this.sum(row, g.bars))}</span></b></div>`
      : ""

    const short = this.hasPartialValue && this.partialValue.map(Number).includes(i)
      ? `<div class="row row-note"><i class="donut-hole-dot"></i>${
        esc(this.partialNoteValue || "period not complete")}</div>`
      : ""

    const text = row.tip
      ? `<div class="row row-note"><i></i>${esc(row.tip)}</div>`
      : ""

    const note = this.hasRuleValue && this.ruleValue.note
      ? `<div class="row row-note"><i></i>${esc(this.ruleValue.note)}</div>`
      : ""

    const tip = chart.querySelector(".tip")
    tip.innerHTML = `<div class="t">${esc(row.label)}</div>${lines}${whole}${text}${short}${note}`
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
    this.pill(chart, at, row.label)

    const cur = chart.querySelector(".cur")
    if (cur) {
      cur.setAttribute("x1", at)
      cur.setAttribute("x2", at)
      cur.setAttribute("opacity", "1")
      chart.querySelectorAll(".dot").forEach((dot) => {
        const v = row[dot.dataset.s]
        if (v == null) return dot.setAttribute("opacity", "0")

        dot.setAttribute("cx", at)
        dot.setAttribute("cy", dot.dataset.axis === "2" && g.y2 ? g.y2(v) : g.y(v))
        dot.setAttribute("opacity", "1")
      })
    }

    chart.querySelector(".chart-caption").textContent = row.gap
      ? `${row.label}, ${row.why || "not fetched"}`
      : `${row.label}, ${g.series.map((s) => `${s.n} ${this.format(row[s.k])}`).join(", ")}${
        this.stack ? `, total ${this.format(this.sum(row, g.bars))}` : ""}`
  }

  pill(chart, at, label) {
    const g = this.geom
    const pill = chart.querySelector(".x-pill")
    if (!pill || !g) return

    const text = String(label)
    const wide = axWide(text) + 20
    const left = clamp(at - wide / 2, g.pad.l - 4, g.wide - g.pad.r - wide + 4)
    const box = pill.querySelector("rect")
    box.setAttribute("x", left.toFixed(1))
    box.setAttribute("width", wide.toFixed(1))
    const say = pill.querySelector("text")
    say.setAttribute("x", (left + wide / 2).toFixed(1))
    say.textContent = text
    pill.setAttribute("opacity", "1")

    chart.querySelectorAll(".xtick").forEach((tick) => {
      const near = Math.abs(Number(tick.dataset.x) - at) < wide / 2 + 18
      if (near) tick.setAttribute("opacity", "0")
      else tick.removeAttribute("opacity")
    })
  }

  clear() {
    const chart = this.element.querySelector(".chart")
    if (!chart) return

    this.at = null
    chart.querySelector(".tip")?.classList.remove("on")
    chart.querySelector(".cur")?.setAttribute("opacity", "0")
    chart.querySelectorAll(".dot").forEach((dot) => dot.setAttribute("opacity", "0"))
    chart.querySelectorAll(".mark").forEach((mark) => mark.classList.remove("fade"))
    chart.querySelector(".x-pill")?.setAttribute("opacity", "0")
    chart.querySelectorAll(".xtick").forEach((tick) => tick.removeAttribute("opacity"))
    const say = chart.querySelector(".chart-caption")
    if (say) say.textContent = ""
  }
}
