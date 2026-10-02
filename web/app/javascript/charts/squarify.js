export function squarify(items, x, y, w, h, out) {
  if (!items.length) return out
  if (items.length === 1) {
    out.push({ ...items[0], x, y, w, h })
    return out
  }

  const total = items.reduce((at, i) => at + i.v, 0)
  let take = 1
  let bestRatio = Infinity
  for (let n = 1; n <= items.length; n++) {
    const part = items.slice(0, n).reduce((at, i) => at + i.v, 0)
    const frac = part / total
    const rw = w >= h ? w * frac : w
    const rh = w >= h ? h : h * frac
    const worst = items.slice(0, n).reduce((mx, i) => {
      const share = i.v / part
      const iw = w >= h ? rw : rw * share
      const ih = w >= h ? rh * share : rh
      return Math.max(mx, Math.max(iw / ih, ih / iw))
    }, 0)
    if (worst < bestRatio) {
      bestRatio = worst
      take = n
    } else break
  }

  const head = items.slice(0, take)
  const tail = items.slice(take)
  const part = head.reduce((at, i) => at + i.v, 0)
  const frac = part / total

  if (w >= h) {
    const rw = w * frac
    let cy = y
    head.forEach((i) => {
      const ih = h * (i.v / part)
      out.push({ ...i, x, y: cy, w: rw, h: ih })
      cy += ih
    })
    return squarify(tail, x + rw, y, w - rw, h, out)
  }

  const rh = h * frac
  let cx = x
  head.forEach((i) => {
    const iw = w * (i.v / part)
    out.push({ ...i, x: cx, y, w: iw, h: rh })
    cx += iw
  })
  return squarify(tail, x, y + rh, w, h - rh, out)
}
