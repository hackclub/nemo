const MARGIN = 12
const FLOOR = 160
const GAP = 5

export function placePop(pop, anchor) {
  const box = anchor.getBoundingClientRect()
  const below = window.innerHeight - box.bottom - MARGIN
  const above = box.top - MARGIN
  const up = below < FLOOR && above > below

  pop.classList.toggle("menu-up", up)
  pop.style.setProperty("--menu-room", `${Math.max(0, Math.round(up ? above : below))}px`)
  if (!pop.hasAttribute("popover")) return

  pop.style.left = "0px"
  pop.style.top = "0px"
  const size = { width: pop.offsetWidth, height: pop.offsetHeight }
  const start = pop.classList.contains("menu-start")
  const left = Math.max(MARGIN, Math.min(start ? box.left : box.right - size.width,
    window.innerWidth - MARGIN - size.width))
  const top = up ? box.top - size.height - GAP : box.bottom + GAP

  pop.style.left = `${Math.round(left)}px`
  pop.style.top = `${Math.round(Math.max(MARGIN,
    Math.min(top, window.innerHeight - MARGIN - size.height)))}px`
}

export function clearPop(pop) {
  pop.style.removeProperty("--menu-room")
  pop.style.removeProperty("left")
  pop.style.removeProperty("top")
  pop.classList.remove("menu-up")
}
